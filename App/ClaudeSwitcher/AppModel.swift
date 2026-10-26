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
    /// Adding several accounts is over: held chats continue.
    case continuing

    var steps: [Step] {
        switch self {
        case .switching: [.quit, .swap, .chats, .launch]
        case .adding: [.quit, .swap, .launch]
        case .waitingForSignIn: [.signIn]
        case .importing, .continuing: [.quit, .chats, .launch]
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
    /// When each account's profile was last read; names and plans change on claude.ai.
    private var profileRead: [String: Date] = [:]
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
            state = Self.seatKeyed(engine.store.loadState())
            // Read from Claude's config, no keychain: the window opens on the signed-in account.
            active = try? engine.desktop.activeAccount()
            activity = Self.loadActivity(engine.store)
        }
    }

    // MARK: - Derived

    var accounts: [Account] { state.accounts }

    /// The active account first, then the others as added.
    var sortedAccounts: [Account] {
        accounts.filter { $0.id == active } + accounts.filter { $0.id != active }
    }

    /// Every account in every workspace, the active account's first.
    var sortedSeats: [Seat] {
        sortedAccounts.flatMap { a in state.seats.filter { $0.account.id == a.id } }
    }

    var hasNotices: Bool {
        error != nil || phase != nil || autoNote != nil || availableUpdate != nil || !cutOff.isEmpty
    }
    var activeAccount: Account? { state.account(active) }
    /// The account Claude is signed in to, in the workspace it has open.
    var activeSeatID: String? { activeAccount.map { Seat.key($0.id, $0.org) } }
    var activeSeat: Seat? { state.seat(activeSeatID) }
    var isBusy: Bool { phase != nil && phase != .waitingForSignIn }
    var suggestion: Seat? { Policy.suggestion(state, active: activeSeatID, now: now) }

    /// The account and workspace with the most of its limits left, signed in or not.
    var roomiest: Seat? {
        state.seats.filter { $0.problem == nil && !$0.excluded && hasSignIn($0.account) && $0.usage != nil }
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
        lastChat = ChatSync.lastChatActivity(root: desktop.sessionsRoot, projects: UsageIndex.defaultProjects)

        await noteActiveOrg()

        // One job per account, or per workspace for an account with several:
        // those read every workspace's limits through claude.ai.
        struct Job {
            var id: String
            var isNew: Bool
            var org: String?
            var key: String { org.map { Seat.key(id, $0) } ?? id }
        }
        var jobs: [Job] = []
        if let current, state.account(current) == nil, now > backoff[current, default: .distantPast] {
            jobs.append(Job(id: current, isNew: true))
        }
        for a in state.accounts where hasSignIn(a) {
            if let orgs = a.orgs, orgs.count > 1 {
                for o in orgs {
                    let job = Job(id: a.id, isNew: false, org: o.id)
                    if isDue(o.usage, active: a.id == current && o.id == a.org), now > backoff[job.key, default: .distantPast] { jobs.append(job) }
                }
            } else if isDue(a.usage, active: a.id == current), now > backoff[a.id, default: .distantPast] {
                jobs.append(Job(id: a.id, isNew: false))
            }
        }

        var added: Account?
        for job in jobs {
            do {
                let usage: Usage
                if let org = job.org, let account = state.account(job.id) {
                    let store = cookieStore(for: account)
                    let ua = AppInfo.webUserAgent
                    usage = try await Task.detached { try await ClaudeWeb(cookieStore: store, userAgent: ua).usage(org: org) }.value
                    state.update(job.id) { a in
                        if let i = a.orgs?.firstIndex(where: { $0.id == org }) { a.orgs?[i].usage = usage; a.orgs?[i].problem = nil }
                        if a.org == org { a.usage = usage; a.problem = nil }
                    }
                    await refreshProfile(job.id, token: nil)
                } else {
                    let token = try await token(for: job.id, active: current)
                    if job.isNew {
                        let profile = try await api.profile(token: token)
                        let account = Account(profile: profile)
                        state.accounts.append(account)
                        added = account
                        record(String(localized: "Added \(account.displayName)."))
                    }
                    await refreshProfile(job.id, token: token)
                    usage = try await api.usage(token: token)
                }
                guard let account = state.account(job.id) else { continue }
                let seat = Seat.key(job.id, job.org ?? account.org)
                let before = job.org == nil || job.org == account.org ? state.history[seat]?.readings.last : nil
                if job.org == nil { state.update(job.id) { $0.usage = usage; $0.problem = nil } }
                state.history[seat, default: UsageHistory()].add(usage)
                if let extra = usage.extra, extra.enabled, let used = extra.usedCents {
                    // claude.ai reports the month so far; keeping the last amount of each day gives the days.
                    state.extraByDay[seat, default: [:]][ExtraLedger.dayKey(now)] = used
                    if state.extraTracks[seat] == nil {
                        state.extraTracks[seat] = ExtraTrack(at: now, amount: used)
                    } else {
                        state.extraTracks[seat]?.record(used, at: now)
                    }
                    if let alert = state.extraAlert, let named = state.seat(seat),
                       let today = ExtraLedger.daily(state.extraByDay[seat] ?? [:])[Calendar.current.startOfDay(for: now)],
                       today >= alert * 100 {
                        notifier.extraToday(named, amount: today / 100, currency: extra.currency, day: ExtraLedger.dayKey(now))
                    }
                }
                if let named = state.seat(seat) {
                    notifier.usageChanged(named, from: before.map { Usage(session: $0.session, sessionReset: nil, weekly: $0.weekly, weeklyReset: nil, checkedAt: $0.date) },
                                          to: usage, model: self)
                }
                strikes[job.key] = nil
            } catch let APIError.rateLimited(after) {
                let n = strikes[job.key, default: 0] + 1
                strikes[job.key] = n
                let wait = after ?? min(Policy.activeEvery * pow(2, Double(n - 1)), Policy.maxBackoff)
                backoff[job.key] = .now.addingTimeInterval(wait)
                log.info("usage \(job.key.prefix(8)): rate limited, next try in \(wait)s")
            } catch APIError.signedOut {
                setProblem(job.id, org: job.org, String(localized: "Signed out. Add it again."))
            } catch {
                setProblem(job.id, org: job.org, error.localizedDescription)
                log.error("usage \(job.key.prefix(8)): \(error.localizedDescription)")
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
        await switchIfDue()
        summarizeYesterdayIfDue()
        await checkForUpdate()
    }

    /// Since when a "soon" switch has been waiting for a pause between replies.
    private var waitingSince: Date?

    /// Runs the automatic switch when the policy calls for one: at once when
    /// the limit runs out within minutes, else at the next pause between
    /// replies, waiting at most `Policy.pauseWait`.
    private func switchIfDue() async {
        // Only "use up expiring weeks" waits for idle chats, so only it needs the process list.
        let live = state.spendWeekly ? ClaudeProcess.liveConversations() : LiveConversations()
        var context = Policy.Context(claudeRunning: claudeRunning, lastChat: lastChat,
                                     commandRunning: !live.runningCommands.isEmpty, now: now)
        guard var decision = Policy.autoTarget(state, active: activeSeatID, context: context) else {
            waitingSince = nil
            warnIfBillingWithoutRoom()
            return
        }
        if decision.1 == .spendWeekly {
            // Worth it only if the week it would use is clearly more than re-reading every open chat.
            let ids = live.ids
            context.switchCost = await Task.detached { SwitchCost.estimate(conversations: ids, projects: UsageIndex.defaultProjects) }.value
            context.dollarsPerWeeklyPercent = await dollarsPerWeeklyPercent()
            guard let again = Policy.autoTarget(state, active: activeSeatID, context: context) else { return }
            decision = again
        }
        if decision.2 == .soon, let last = lastChat, now.timeIntervalSince(last) < Policy.pause {
            let since = waitingSince ?? now
            waitingSince = since
            if now.timeIntervalSince(since) < Policy.pauseWait { return }
        }
        waitingSince = nil
        await switchTo(decision.0, cause: decision.1)
    }

    /// What a percent of the signed-in account's weekly limit cost lately at
    /// API prices, from its last three hours: the API value of its usage
    /// against how far its week moved. Nil until the week has moved a percent.
    private func dollarsPerWeeklyPercent() async -> Double? {
        guard let id = active, let seat = activeSeatID, let readings = state.history[seat]?.readings, let last = readings.last,
              let first = readings.first(where: { now.timeIntervalSince($0.date) <= Forecast.weeklyWindow }),
              last.weekly - first.weekly >= 1 else { return nil }
        await insights.updateBuckets()
        let spent = UsageReport.make(insights.buckets, timeline: timeline, range: first.date...last.date,
                                     filter: UsageFilter(accounts: [id])).total.cost
        return spent / (last.weekly - first.weekly)
    }

    /// With extra usage on and no account to move to, running out costs
    /// money: say so once an hour.
    private func warnIfBillingWithoutRoom() {
        guard state.autoSwitch, let account = activeAccount, let usage = account.usage?.current(at: now),
              account.usage?.extra?.enabled == true, usage.peak >= 100 else { return }
        notifier.billingWithoutRoom(account, hour: Int(now.timeIntervalSince1970 / 3600))
    }

    // MARK: - Pause

    var isPaused: Bool { state.pausedUntil.map { now < $0 } ?? false }

    /// When an account's limits run out at the pace of its last checks.
    func forecast(_ account: Account) -> Forecast? {
        state.seat(of: account).flatMap(forecast)
    }

    func forecast(_ seat: Seat) -> Forecast? {
        seat.usage.map { Forecast(usage: $0, history: state.history[seat.id], now: now) }
    }

    /// Leaves a workspace out of automatic switching, or takes it back in.
    func setExcluded(_ seat: Seat, _ excluded: Bool) {
        state.update(seat.account.id) { a in
            if let i = a.orgs?.firstIndex(where: { $0.id == seat.orgID }) { a.orgs?[i].excluded = excluded }
        }
        save()
    }

    func pauseAutoSwitch(for duration: TimeInterval = 2 * 3600) {
        state.pausedUntil = .now.addingTimeInterval(duration)
        save()
        record(String(localized: "Automatic switching paused until \(state.pausedUntil!.formatted(date: .omitted, time: .shortened))."))
    }

    func resumeAutoSwitch() {
        state.pausedUntil = nil
        save()
        record(String(localized: "Automatic switching resumed."))
    }

    // MARK: - Morning summary

    /// After 8 in the morning, once a day: the day before in one notification.
    private func summarizeYesterdayIfDue() {
        let cal = Calendar.current
        guard state.notify, state.morningSummary, !isDemo, cal.component(.hour, from: now) >= 8,
              let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now)) else { return }
        let key = ExtraLedger.dayKey(yesterday)
        guard state.summaryDay != key else { return }
        state.summaryDay = key
        save()
        Task {
            await insights.updateBuckets()
            let day = yesterday...cal.startOfDay(for: now).addingTimeInterval(-1)
            let total = UsageReport.make(insights.buckets, timeline: timeline, range: day).total
            let switches = timeline.signIns.filter { day.contains($0.date) }.count
            var billed: [String] = []
            for seat in state.seats {
                if let minor = ExtraLedger.daily(state.extraByDay[seat.id] ?? [:])[yesterday], minor > 0 {
                    billed.append("\(seat.displayName) \(money(minor / 100, seat.usage?.extra?.currency))")
                }
            }
            notifier.morningSummary(apiValue: total.cost, replies: total.tokens.messages, switches: switches, billed: billed)
        }
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

    private func isDue(_ usage: Usage?, active: Bool) -> Bool {
        let every = Policy.interval(usage: usage, active: active, now: now)
        return usage.map { now.timeIntervalSince($0.checkedAt) >= every - 5 } ?? true
    }

    private func setProblem(_ id: String, org: String?, _ problem: String) {
        state.update(id) { a in
            if let org, let i = a.orgs?.firstIndex(where: { $0.id == org }) { a.orgs?[i].problem = problem } else { a.problem = problem }
        }
    }

    /// Every half hour: the name Claude calls you, the email and the plan
    /// (from the profile, when there is a token), and the account's
    /// workspaces (from claude.ai).
    private func refreshProfile(_ id: String, token: String?) async {
        guard profileRead[id].map({ now.timeIntervalSince($0) > 30 * 60 }) ?? true, let account = state.account(id) else { return }
        profileRead[id] = now
        if let token, let profile = try? await api.profile(token: token),
           account.name != profile.name || account.email != profile.email || account.plan != profile.plan {
            state.update(id) { $0.name = profile.name; $0.email = profile.email; $0.plan = profile.plan }
            if account.name != profile.name, let renamed = state.account(id) {
                record(String(localized: "\(account.displayName) is now called \(renamed.displayName), as on claude.ai."))
            }
        }
        let store = cookieStore(for: account)
        let ua = AppInfo.webUserAgent
        guard let orgs = try? await Task.detached(operation: { try await ClaudeWeb(cookieStore: store, userAgent: ua).orgs() }).value else { return }
        state.update(id) { a in
            guard orgs.count > 1 else { a.orgs = nil; return }
            // Keep what is known of each workspace: its limits and whether it is left out.
            a.orgs = orgs.map { o in
                var merged = o
                if let old = a.orgs?.first(where: { $0.id == o.id }) {
                    merged.usage = old.usage
                    merged.problem = old.problem
                    merged.excluded = old.excluded
                } else if o.id == a.org {
                    merged.usage = a.usage
                }
                return merged
            }
        }
        if (state.account(id)?.orgs?.count ?? 0) > 1, account.orgs == nil {
            record(String(localized: "\(account.displayName) has \(orgs.count) workspaces: \(orgs.map(\.label).joined(separator: ", ")). Each one\u{2019}s limits count."))
        }
    }

    /// The workspace Claude has open, for an account with several: claude.ai's
    /// `lastActiveOrg` cookie in Claude's own cookie store. A switch made in
    /// Claude itself shows up here too.
    private func noteActiveOrg() async {
        guard let account = activeAccount, let orgs = account.orgs, orgs.count > 1 else { return }
        let store = engine.desktop.cookieFiles[0]
        guard let org = try? await Task.detached(operation: { try ClaudeWeb.cookie("lastActiveOrg", in: store) }).value,
              org != account.org, orgs.contains(where: { $0.id == org }) else { return }
        state.update(account.id) { a in
            a.org = org
            a.usage = a.orgs?.first { $0.id == org }?.usage
        }
        save()
    }

    // MARK: - Actions

    /// Switches to an account in the workspace it last had open.
    func switchTo(_ target: Account, cause: SwitchCause = .byHand) async {
        guard let seat = state.seat(of: target) else { return }
        await switchTo(seat, cause: cause)
    }

    /// Switches Claude to an account, or to another workspace of the signed-in
    /// account (which only changes the workspace claude.ai has open).
    func switchTo(_ target: Seat, cause: SwitchCause = .byHand) async {
        let from = activeSeatID
        guard target.id != from else { return }
        let accounts = state.accounts
        let mirror = state.mirrorSettings
        let name = target.displayName
        let done: (SwitchReport) -> Void = { [weak self] report in
            self?.record(Self.describe(switchTo: name, cause: cause, report: report))
            self?.cutOff = report.cutOff
            self?.continueRest(report.cutOff)
        }
        let ok: Bool
        if target.account.id == active {
            let org = target.orgID
            ok = await restart(.switching(to: name)) { engine in try engine.switchOrg(to: org, accounts: accounts) } done: { done($0) }
        } else {
            let org = target.org == nil ? nil : target.orgID
            ok = await restart(.switching(to: name)) { engine in
                try engine.switchFiles(to: target.account, org: org, accounts: accounts, mirrorSettings: mirror)
            } done: { done($0) }
        }
        guard ok else { return }
        state.update(target.account.id) { a in
            a.org = target.orgID
            if let org = a.orgs?.first(where: { $0.id == target.orgID }) { a.usage = org.usage }
        }
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
        active = target.account.id
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
    func setMorningSummary(_ on: Bool) { state.morningSummary = on; save() }
    func setExtraAlert(_ amount: Double?) { state.extraAlert = amount; save() }

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

    /// The page the main window shows; the app menu's Settings… opens it on Settings.
    var selection: SidebarItem?

    /// Claude Switcher → Settings… (⌘,): the window's own Settings page, not a second window.
    func showSettings() {
        selection = .settings
        showMainWindow?()
    }

    /// A claude.ai page open inside Claude Switcher, as one account.
    var claudeAIPage: ClaudeAIPage?

    /// Opens claude.ai's Connectors page as `account`, to sign in to connectors
    /// there. Its setup is read again once the page is closed.
    func connect(_ account: Account) {
        claudeAIPage = ClaudeAIPage(account: account, path: "/settings/connectors")
    }

    func closeClaudeAIPage() {
        claudeAIPage = nil
        Task { await refreshCloudSetups(force: true) }
    }

    /// An account's claude.ai cookies, decrypted off the main thread.
    func webCookies(for account: Account) async throws -> [HTTPCookie] {
        let store = cookieStore(for: account)
        return try await Task.detached { try ClaudeWeb.webCookies(cookieStore: store) }.value
    }

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
        guard !state.holdChats else { return }
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

    /// Adding several accounts: while on, restarts keep cut-off chats waiting
    /// and nothing switches on its own. Turning it off continues them all in
    /// the account Claude is signed in with, which takes one more restart.
    func setHoldChats(_ on: Bool) async {
        guard on != state.holdChats, !isBusy else { return }
        state.holdChats = on
        save()
        if on {
            record(String(localized: "Adding several accounts: chats wait until this is turned off."))
            return
        }
        let ids = state.heldChats
        guard !ids.isEmpty else { return }
        let accounts = state.accounts
        let ok = await restart(.continuing) { engine in try engine.continueHeld(ids, accounts: accounts) } done: { [weak self] report in
            guard let self else { return }
            self.cutOff = report.cutOff
            self.record(String(localized: "Done adding accounts: \(report.cutOff.count) waiting chats continue in \(self.activeAccount?.displayName ?? "")."))
            self.continueRest(report.cutOff)
        }
        if ok {
            state.heldChats = []
            save()
        } else {
            // Nothing was continued: keep holding, so the chats are not lost.
            state.holdChats = true
            save()
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
        let holding = state.holdChats
        do {
            step = .quit
            let live = try await ClaudeProcess.quit()
            step = phase.steps.contains(.swap) ? .swap : .chats
            var engine = engine
            engine.liveConversations = live
            let result: R
            let held: [String]
            do {
                (result, held) = try await Task.detached {
                    let result = try change(engine)
                    // Adding several accounts: what this restart cut off waits.
                    return (result, holding ? try engine.holdChats() : [])
                }.value
            } catch {
                try? await ClaudeProcess.launch(appURL)
                throw error
            }
            step = .launch
            try await ClaudeProcess.launch(appURL)
            done(result)
            if holding {
                state.heldChats += held.filter { !state.heldChats.contains($0) }
                cutOff = []
                save()
            }
            outcome = Outcome(succeeded: true, title: Self.doneTitle(phase, signedIn: activeAccount),
                              detail: holding ? Self.heldDetail(state.heldChats.count) : Self.doneDetail(phase, cutOff: cutOff))
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
        case .continuing: String(localized: "Chats continue")
        case .waitingForSignIn: ""
        }
    }

    private static func heldDetail(_ count: Int) -> String {
        count == 0
            ? String(localized: "No chats were cut off.")
            : String(localized: "\(count) chats wait until you are done adding accounts.")
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

    /// Claude Switcher → Check for Updates…: asks GitHub now and says what it found.
    func checkForUpdatesNow() async {
        let alert = NSAlert()
        do {
            guard updates.isConfigured else { throw APIError.status(0) }
            let release = try await updates.latest()
            state.latestVersion = release.version
            state.updateChecked = .now
            save()
            if UpdateChecker.isNewer(release.version, than: AppInfo.version) {
                alert.messageText = String(localized: "Claude Switcher \(release.version) is available")
                alert.informativeText = String(localized: "You have \(AppInfo.version). Download the new version from its release page and drag it onto Applications; your accounts stay.")
                alert.addButton(withTitle: String(localized: "Download"))
                alert.addButton(withTitle: String(localized: "Later"))
            } else {
                alert.messageText = String(localized: "Claude Switcher is up to date")
                alert.informativeText = String(localized: "\(AppInfo.version) is the latest version.")
            }
        } catch {
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Could not check for updates")
            alert.informativeText = String(localized: "GitHub did not answer. Try again in a moment.")
        }
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn, alert.buttons.count == 2 { openReleasePage() }
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

    /// History, extra usage and the spending mark are kept per account and
    /// workspace ("<account>/<org>"); state from before workspaces had them
    /// per account.
    private static func seatKeyed(_ state: SwitcherState) -> SwitcherState {
        var s = state
        func key(_ k: String) -> String { k.contains("/") ? k : s.account(k).map { Seat.key($0.id, $0.org) } ?? k }
        s.history = Dictionary(s.history.map { (key($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        s.extraTracks = Dictionary(s.extraTracks.map { (key($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        s.extraByDay = Dictionary(s.extraByDay.map { (key($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        s.spending = s.spending.map(key)
        s.lastFrom = s.lastFrom.map(key)
        return s
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

    private static func describe(switchTo name: String, cause: SwitchCause, report: SwitchReport) -> String {
        let base = switch cause {
        case .byHand: String(localized: "Switched to \(name).")
        case .nearlyFull: String(localized: "Switched to \(name) on its own: the active account was nearly full.")
        case .spendWeekly: String(localized: "Switched to \(name) on its own to use its week before it resets.")
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
