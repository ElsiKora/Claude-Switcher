import AppKit
import Observation
import OSLog
import ServiceManagement
import SwitcherCore

let log = Logger(subsystem: "com.elsikora.ClaudeSwitcher", category: "switcher")

/// One line of what the switcher did, newest first in the window.
struct Activity: Identifiable, Equatable, Codable {
    var id = UUID()
    let date: Date
    let text: String
    let isError: Bool
}

/// A restart of Claude in progress.
enum Phase: Equatable {
    case switching(to: String)
    case adding
    case waitingForSignIn
    case importing

    var steps: [Step] {
        switch self {
        case .switching: [.quit, .swap, .chats, .launch]
        case .adding: [.quit, .swap, .launch]
        case .waitingForSignIn: [.signIn]
        case .importing: [.quit, .chats, .launch]
        }
    }

    enum Step: Equatable {
        case quit, swap, chats, launch, signIn
    }
}

@MainActor
@Observable
final class AppModel {
    /// The one model of the app; App Intents reach it here.
    static let shared = AppModel(demo: ClaudeSwitcherApp.isDemo)

    private(set) var state: SwitcherState
    private(set) var active: String?
    private(set) var claudeRunning = false
    private(set) var lastChat: Date?
    private(set) var phase: Phase?
    private(set) var step: Phase.Step?
    private(set) var error: String?
    private(set) var activity: [Activity] = []
    private(set) var startsAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var now = Date.now
    /// The account being brought up to the reference account's setup right now.
    private(set) var copyingSetupTo: String?
    /// What the last Copy Setup into each account did.
    private(set) var setupCopies: [String: SetupCopy.Result] = [:]
    /// How the last restart ended, shown by the HUD.
    private(set) var outcome: Outcome?
    let hud = SwitchHUD()
    /// Chats the last restart cut off mid-turn, which Claude continues.
    private(set) var cutOff: [CutOffTurns.Chat] = []
    /// What each account has set up on claude.ai, read live.
    private(set) var cloudSetups: [String: CloudSetup] = [:]
    /// Why an account's claude.ai setup could not be read.
    private(set) var cloudErrors: [String: String] = [:]
    private var cloudReadAt: [String: Date] = [:]

    let engine: SwitchEngine
    let api = AnthropicAPI(userAgent: "ClaudeSwitcher/\(AppInfo.version)")
    let updates = UpdateChecker(repository: AppInfo.updateRepository)

    private var addingSince: Date?
    /// The account that was signed in when Add Account started; a new
    /// account gets its Claude Code settings.
    private var addingFrom: Account?
    private var backoff: [String: Date] = [:]
    private var strikes: [String: Int] = [:]
    private var loop: Task<Void, Never>?
    /// The refresh under way; the loop, the window and the menu panel all
    /// ask for one, and they share it.
    private var refreshing: Task<Void, Never>?

    /// Sample accounts and no access to Claude, for screenshots of the design.
    let isDemo: Bool

    init(demo: Bool = false) {
        isDemo = demo
        if demo {
            engine = SwitchEngine(store: Store(root: FileManager.default.temporaryDirectory.appending(path: "claude-switcher-demo")))
            state = Demo.state
            active = Demo.state.accounts.first?.id
            claudeRunning = true
            activity = Demo.activity
            cloudSetups = Demo.cloudSetups
        } else {
            engine = SwitchEngine()
            state = engine.store.loadState()
            activity = Self.loadActivity(engine.store)
        }
    }

    // MARK: - Derived

    var accounts: [Account] { state.accounts }

    /// The active account first, then the others as added.
    var sortedAccounts: [Account] {
        accounts.filter { $0.id == active } + accounts.filter { $0.id != active }
    }

    var hasNotices: Bool {
        error != nil || phase != nil || autoNote != nil || availableUpdate != nil || !cutOff.isEmpty
    }
    var activeAccount: Account? { state.account(active) }
    var isBusy: Bool { phase != nil && phase != .waitingForSignIn }
    var suggestion: Account? { Policy.suggestion(state, active: active, now: now) }

    /// The account with the most of its limits left, signed in or not.
    var roomiest: Account? {
        accounts.filter { $0.problem == nil && hasSignIn($0) && $0.usage != nil }
            .min { ($0.usage!.current(at: now).peak) < ($1.usage!.current(at: now).peak) }
    }

    var availableUpdate: String? {
        guard state.checkForUpdates, updates.isConfigured, let latest = state.latestVersion,
              UpdateChecker.isNewer(latest, than: AppInfo.version) else { return nil }
        return latest
    }

    /// Why the last switch happened, when the switcher made it on its own, for 12 hours.
    var autoNote: String? {
        guard let at = state.lastSwitch, now.timeIntervalSince(at) < 12 * 3600 else { return nil }
        let time = at.formatted(date: .omitted, time: .shortened)
        switch state.lastCause {
        case .nearlyFull:
            let from = state.account(state.lastFrom)?.displayName ?? String(localized: "the last account")
            return String(localized: "Switched at \(time): \(from) was nearly full.")
        case .spendWeekly:
            let reset = state.spendUntil?.formatted(.dateTime.weekday().hour().minute()) ?? ""
            return String(localized: "Switched at \(time) to use this account\u{2019}s week before it resets \(reset).")
        case .byHand, nil:
            return nil
        }
    }

    /// The account the others are set up like: the chosen one, else the one
    /// with the most connectors, skills and plugins.
    var referenceAccount: Account? {
        if let chosen = state.account(state.reference) { return chosen }
        return accounts.max { (cloudSetups[$0.id]?.count ?? 0) < (cloudSetups[$1.id]?.count ?? 0) }
    }

    /// What `account` lacks compared with the reference account.
    func setupGaps(_ account: Account) -> CloudSetup.Gaps? {
        guard let reference = referenceAccount, reference.id != account.id,
              let mine = cloudSetups[account.id], let theirs = cloudSetups[reference.id] else { return nil }
        return mine.gaps(from: theirs)
    }

    /// Reads the claude.ai setup of every account with a session, at most every five minutes unless forced.
    func refreshCloudSetups(force: Bool = false) async {
        guard !isDemo else { return }
        let ua = AppInfo.webUserAgent
        for account in accounts where hasSignIn(account) {
            if !force, let at = cloudReadAt[account.id], now.timeIntervalSince(at) < 300 { continue }
            cloudReadAt[account.id] = now
            let store = cookieStore(for: account)
            do {
                cloudSetups[account.id] = try await Task.detached {
                    try await CloudSetup.read(ClaudeWeb(cookieStore: store, userAgent: ua), org: account.org)
                }.value
                cloudErrors[account.id] = nil
            } catch {
                cloudErrors[account.id] = error.localizedDescription
            }
        }
    }

    func hasSignIn(_ account: Account) -> Bool {
        isDemo || account.id == active || engine.store.hasSignIn(account.id)
    }

    /// What the last restart left for Claude to continue.
    var cutOffSummary: String {
        let sides = cutOff.reduce(0) { $0 + $1.sideSessions }
        return sides > 0
            ? String(localized: "Claude continues \(cutOff.count) chats cut off by the restart; they check on \(sides) side sessions.")
            : String(localized: "Claude continues \(cutOff.count) chats cut off by the restart.")
    }

    // MARK: - Loop

    let notifier = Notifier()
    @ObservationIgnored lazy var insights = Insights(store: engine.store)

    /// Which account was signed in when; built once from the switcher's
    /// backups and the chat lists as they were before the first switch.
    var timeline: AccountTimeline {
        if let t = state.timeline { return t }
        var t = AccountTimeline()
        let before = engine.store.safetyBackupRoot.appending(path: "claude-code-sessions")
        t.native = AccountTimeline.native(from: FileManager.default.fileExists(atPath: before.path) ? before : engine.desktop.sessionsRoot)
        for s in AccountTimeline.fromBackups(engine.store.backupsRoot, current: active) { t.record(s.account, at: s.date) }
        return t
    }

    /// From now on, usage counts for the account signed in now.
    private func noteSignIn() {
        var t = timeline
        t.record(active, at: now)
        if t != state.timeline {
            state.timeline = t
            save()
        }
    }
    /// Set by the menu bar label, which can open windows.
    var showMainWindow: (() -> Void)?
    var showWelcome: (() -> Void)?

    /// `--demo --hud`: the switch HUD mid-switch, then finished, for screenshots.
    func showDemoHUD() {
        guard isDemo else { return }
        phase = .switching(to: "Studio")
        step = .chats
        hud.show(self)
        Task {
            try? await Task.sleep(for: .seconds(6))
            phase = nil
            step = nil
            outcome = Outcome(succeeded: true, title: "Signed in as Studio", detail: "2 chats continue and check on 6 side sessions.")
            Feedback.success(sound: false)
            hud.finish(after: 8)
        }
    }

    func start() {
        guard loop == nil, !isDemo else { return }
        notifier.start()
        if !state.onboarded {
            if accounts.count >= 2 { finishOnboarding() } else { showWelcome?() }
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    /// Notices sign-ins, keeps usage current and runs the automatic switch.
    /// Callers that ask while one runs wait for that one, so a new sign-in
    /// is added once.
    func refresh() async {
        if let refreshing { return await refreshing.value }
        let task = Task { await performRefresh() }
        refreshing = task
        await task.value
        refreshing = nil
    }

    private func performRefresh() async {
        now = .now
        guard !isDemo else { return }
        claudeRunning = ClaudeProcess.isRunning
        guard !isBusy else { return }
        let desktop = engine.desktop
        let current = try? desktop.activeAccount()
        active = current
        if current != nil { noteSignIn() }
        lastChat = ChatSync.lastChatWrite(root: desktop.sessionsRoot)

        var jobs: [(id: String, isNew: Bool)] = []
        if let current, state.account(current) == nil, now > backoff[current, default: .distantPast] {
            jobs.append((current, true))
        }
        for a in state.accounts {
            let every = Policy.interval(for: a, active: a.id == current, now: now)
            let due = a.usage.map { now.timeIntervalSince($0.checkedAt) >= every - 5 } ?? true
            if due, now > backoff[a.id, default: .distantPast], hasSignIn(a) {
                jobs.append((a.id, false))
            }
        }

        var added: Account?
        for job in jobs {
            do {
                let token = try await token(for: job.id, active: current)
                if job.isNew {
                    let profile = try await api.profile(token: token)
                    let account = Account(profile: profile)
                    state.accounts.append(account)
                    added = account
                    record(String(localized: "Added \(account.displayName)."))
                }
                let usage = try await api.usage(token: token)
                let before = state.account(job.id)?.usage
                state.update(job.id) { $0.usage = usage; $0.problem = nil }
                if let account = state.account(job.id) { notifier.usageChanged(account, from: before, to: usage, model: self) }
                strikes[job.id] = nil
            } catch let APIError.rateLimited(after) {
                let n = strikes[job.id, default: 0] + 1
                strikes[job.id] = n
                let wait = after ?? min(Policy.activeEvery * pow(2, Double(n - 1)), Policy.maxBackoff)
                backoff[job.id] = .now.addingTimeInterval(wait)
                log.info("usage \(job.id.prefix(8)): rate limited, next try in \(wait)s")
            } catch APIError.signedOut {
                state.update(job.id) { $0.problem = String(localized: "Signed out. Add it again.") }
            } catch {
                state.update(job.id) { $0.problem = error.localizedDescription }
                log.error("usage \(job.id.prefix(8)): \(error.localizedDescription)")
            }
        }
        save()

        if let added, addingSince != nil {
            addingSince = nil
            phase = nil
            // A fresh sign-in: restart once so the chats of the other accounts show up.
            await importChats(into: added, mirrorFrom: state.mirrorSettings ? addingFrom : nil)
            addingFrom = nil
            return
        }
        if addingSince.map({ now.timeIntervalSince($0) > 15 * 60 }) == true {
            addingSince = nil
            phase = nil
        }
        if let (target, cause) = Policy.autoTarget(state, active: active, claudeRunning: claudeRunning, lastChat: lastChat, now: now) {
            await switchTo(target, cause: cause)
        }
        await checkForUpdate()
    }

    /// An access token for an account: from Claude's live config when it is
    /// signed in, otherwise from its saved sign-in. Decrypted off the main
    /// thread, because the first keychain read waits for the user.
    private func token(for id: String, active: String?) async throws -> String {
        let url = id == active ? engine.desktop.configURL : engine.store.signInDir(id).appending(path: "config.json")
        return try await Task.detached {
            try TokenCache.accessToken(fromEncrypted: ClaudeDesktop.tokenCache(in: url), account: id)
        }.value
    }

    // MARK: - Actions

    func switchTo(_ target: Account, cause: SwitchCause = .byHand) async {
        let from = active
        let accounts = state.accounts
        let mirror = state.mirrorSettings
        let ok = await restart(.switching(to: target.displayName)) { engine in
            try engine.switchFiles(to: target, accounts: accounts, mirrorSettings: mirror)
        } done: { [weak self] report in
            self?.record(Self.describe(switchTo: target, cause: cause, report: report))
            self?.cutOff = report.cutOff
            self?.continueRest(report.cutOff)
        }
        guard ok else { return }
        state.lastSwitch = .now
        state.lastCause = cause
        state.lastFrom = from
        switch cause {
        case .byHand:
            state.handSwitch = .now
            state.spending = nil
            state.spendUntil = nil
        case .spendWeekly:
            state.spending = target.id
            state.spendUntil = target.usage?.weeklyReset
        case .nearlyFull:
            break
        }
        active = target.id
        save()
    }

    func addAccount() async {
        addingFrom = activeAccount
        let accounts = state.accounts
        let ok = await restart(.adding) { engine in try engine.prepareAdd(accounts: accounts) } done: { [weak self] chats in
            self?.cutOff = chats
            self?.record(String(localized: "Claude is on its sign-in screen. Sign in with the other account."))
        }
        if ok {
            addingSince = .now
            phase = .waitingForSignIn
            step = .signIn
        }
    }

    func cancelAdding() {
        addingSince = nil
        phase = nil
        step = nil
    }

    func importChats(into account: Account, mirrorFrom source: Account? = nil) async {
        await restart(.importing) { engine in try engine.importChats(into: account, mirrorFrom: source) } done: { [weak self] report in
            guard let self else { return }
            self.record(String(localized: "Brought \(report.chats) chats and \(report.projects) projects into \(account.displayName)."))
            // Chats Add Account cut off continue in the new account.
            self.continueRest(self.cutOff)
        }
    }

    func remove(_ account: Account) {
        guard account.id != active else { return }
        try? FileManager.default.removeItem(at: engine.store.signInDir(account.id))
        state.accounts.removeAll { $0.id == account.id }
        save()
        record(String(localized: "Removed \(account.displayName)."))
    }

    func setAutoSwitch(_ on: Bool) { state.autoSwitch = on; save() }
    func setSpendWeekly(_ on: Bool) { state.spendWeekly = on; save() }
    func setThreshold(_ t: Double) { state.threshold = t; save() }
    func setCheckForUpdates(_ on: Bool) { state.checkForUpdates = on; save() }
    func setPlaySounds(_ on: Bool) { state.playSounds = on; save() }

    func setNotify(_ on: Bool) async {
        let allowed = on ? await notifier.requestPermission() : false
        state.notify = allowed
        save()
    }

    func finishOnboarding() {
        state.onboarded = true
        save()
        if state.notify { Task { _ = await notifier.requestPermission() } }
    }
    func setMirrorSettings(_ on: Bool) { state.mirrorSettings = on; save() }
    func setReference(_ id: String?) { state.reference = id; save() }

    /// Opens a claude.ai page inside Claude, in the account it is signed in with.
    func openInClaude(_ path: String) {
        if let url = URL(string: "claude://claude.ai\(path)") { NSWorkspace.shared.open(url) }
    }
    func dismissError() { error = nil }

    /// The cookie store with an account's claude.ai session: Claude's own for
    /// the signed-in account, the saved copy for the others.
    private func cookieStore(for account: Account) -> URL {
        account.id == active
            ? engine.desktop.cookieFiles[0]
            : engine.store.signInDir(account.id).appending(path: "Cookies")
    }

    /// Brings `account` up to the reference account's claude.ai setup.
    func copySetup(to account: Account) async {
        guard let reference = referenceAccount, reference.id != account.id, copyingSetupTo == nil else { return }
        copyingSetupTo = account.id
        defer { copyingSetupTo = nil }
        let from = cookieStore(for: reference)
        let to = cookieStore(for: account)
        let ua = AppInfo.webUserAgent
        do {
            let result = try await Task.detached {
                try await SetupCopy(
                    reference: ClaudeWeb(cookieStore: from, userAgent: ua), referenceOrg: reference.org,
                    target: ClaudeWeb(cookieStore: to, userAgent: ua), targetOrg: account.org
                ).run()
            }.value
            setupCopies[account.id] = result
            var text = String(localized: "Set up \(account.displayName) like \(reference.displayName): \(result.connectors.count) connectors, \(result.plugins.count) plugins, \(result.skills.count) skills, \(result.toolSettings) tool settings.")
            if !result.failed.isEmpty { text += " " + String(localized: "Not done: \(result.failed.joined(separator: ", ")).") }
            record(text)
        } catch {
            fail(String(localized: "Could not copy the setup: \(error.localizedDescription)"))
        }
        await refreshCloudSetups(force: true)
    }

    func dismissCutOff() { cutOff = [] }

    /// Claude continues the four most recent marked chats on its own and the
    /// rest when they are opened, so the rest are opened one by one.
    private func continueRest(_ chats: [CutOffTurns.Chat]) {
        let rest = Array(chats.dropFirst(4))
        guard !rest.isEmpty else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(25))
            for chat in rest {
                guard let self, ClaudeProcess.isRunning else { return }
                self.open(chat)
                try? await Task.sleep(for: .seconds(6))
            }
        }
    }

    /// Opens a chat in Claude; opening a chat whose turn was cut off continues it.
    func open(_ chat: CutOffTurns.Chat) {
        if let url = URL(string: "claude://code/continue?session=local_\(chat.id)") { NSWorkspace.shared.open(url) }
    }

    func setStartsAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            fail(String(localized: "Start at login: \(error.localizedDescription)"))
        }
        startsAtLogin = SMAppService.mainApp.status == .enabled
    }

    func openDataFolder() { NSWorkspace.shared.open(engine.store.root) }

    // MARK: - Restart

    /// Closes Claude, runs `change` on its files and starts Claude again. A
    /// failed change has already put Claude's files back.
    @discardableResult
    private func restart<R: Sendable>(
        _ phase: Phase,
        change: @escaping @Sendable (SwitchEngine) throws -> R,
        done: (R) -> Void
    ) async -> Bool {
        guard !isBusy else { return false }
        self.phase = phase
        error = nil
        outcome = nil
        hud.show(self)
        defer {
            if self.phase == phase { self.phase = nil }
            step = nil
        }
        let appURL = ClaudeProcess.appURL
        do {
            step = .quit
            let live = try await ClaudeProcess.quit()
            step = phase.steps.contains(.swap) ? .swap : .chats
            var engine = engine
            engine.liveConversations = live
            let result: R
            do {
                result = try await Task.detached { try change(engine) }.value
            } catch {
                try? await ClaudeProcess.launch(appURL)
                throw error
            }
            step = .launch
            try await ClaudeProcess.launch(appURL)
            done(result)
            outcome = Outcome(succeeded: true, title: Self.doneTitle(phase, signedIn: activeAccount),
                              detail: Self.doneDetail(phase, cutOff: cutOff))
            Feedback.success(sound: state.playSounds)
            hud.finish()
            return true
        } catch {
            fail(error.localizedDescription)
            outcome = Outcome(succeeded: false, title: String(localized: "The switch did not go through"), detail: error.localizedDescription)
            Feedback.failure(sound: state.playSounds)
            hud.finish(after: 5)
            return false
        }
    }

    private static func doneTitle(_ phase: Phase, signedIn: Account?) -> String {
        switch phase {
        case let .switching(name): String(localized: "Signed in as \(name)")
        case .adding: String(localized: "Ready for the next account")
        case .importing: String(localized: "Chats brought along")
        case .waitingForSignIn: ""
        }
    }

    private static func doneDetail(_ phase: Phase, cutOff: [CutOffTurns.Chat]) -> String {
        if case .adding = phase { return String(localized: "Sign in to Claude with the other account.") }
        guard !cutOff.isEmpty else { return String(localized: "Claude is starting.") }
        let sides = cutOff.reduce(0) { $0 + $1.sideSessions }
        return sides > 0
            ? String(localized: "\(cutOff.count) chats continue and check on \(sides) side sessions.")
            : String(localized: "\(cutOff.count) chats continue where they stopped.")
    }

    // MARK: - Updates

    private func checkForUpdate() async {
        guard state.checkForUpdates, updates.isConfigured,
              state.updateChecked.map({ now.timeIntervalSince($0) > 24 * 3600 }) ?? true else { return }
        state.updateChecked = .now
        if let release = try? await updates.latest() { state.latestVersion = release.version }
        save()
    }

    func openReleasePage() {
        NSWorkspace.shared.open(URL(string: "https://github.com/\(updates.repository)/releases/latest")!)
    }

    // MARK: - Helpers

    private func save() {
        do { try engine.store.save(state) } catch { log.error("save state: \(error.localizedDescription)") }
    }

    private func record(_ text: String) {
        log.notice("\(text, privacy: .public)")
        add(Activity(date: .now, text: text, isError: false))
    }

    /// The journal is kept on disk, so it outlives a restart of this app.
    private func add(_ item: Activity) {
        activity.insert(item, at: 0)
        activity = Array(activity.prefix(200))
        guard !isDemo else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(activity) {
            try? Files.writeAtomically(data, to: engine.store.root.appending(path: "activity.json"))
        }
    }

    private static func loadActivity(_ store: Store) -> [Activity] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: store.root.appending(path: "activity.json")) else { return [] }
        return (try? decoder.decode([Activity].self, from: data)) ?? []
    }

    private func fail(_ text: String) {
        log.error("\(text, privacy: .public)")
        error = text
        add(Activity(date: .now, text: text, isError: true))
    }

    private static func describe(switchTo target: Account, cause: SwitchCause, report: SwitchReport) -> String {
        let base = switch cause {
        case .byHand: String(localized: "Switched to \(target.displayName).")
        case .nearlyFull: String(localized: "Switched to \(target.displayName) on its own: the active account was nearly full.")
        case .spendWeekly: String(localized: "Switched to \(target.displayName) on its own to use its week before it resets.")
        }
        var text = base + " " + String(localized: "\(report.chats) chats and \(report.projects) projects brought along.")
        if report.settingsMirrored { text += " " + String(localized: "Claude Code settings copied over.") }
        if !report.cutOff.isEmpty { text += " " + String(localized: "\(report.cutOff.count) chats cut off mid-reply continue there.") }
        return text
    }
}

enum AppInfo {
    /// claude.ai answers browsers; the probe that read connectors used this one.
    static let webUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// `owner/name` of the GitHub repository with releases; empty turns the check off.
    static var updateRepository: String {
        Bundle.main.object(forInfoDictionaryKey: "SwitcherUpdateRepository") as? String ?? ""
    }
}
