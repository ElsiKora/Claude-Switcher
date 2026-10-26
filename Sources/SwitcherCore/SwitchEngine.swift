public import Foundation

/// Where the switcher keeps saved sign-ins, backups and its state.
public struct Store: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static var standard: Store {
        Store(root: URL.applicationSupportDirectory.appending(path: "Claude Switcher", directoryHint: .isDirectory))
    }

    public var stateURL: URL { root.appending(path: "state.json") }
    public var backupsRoot: URL { root.appending(path: "backups", directoryHint: .isDirectory) }
    public var spacesSeenURL: URL { root.appending(path: "spaces-seen.json") }
    public var scheduledSeenURL: URL { root.appending(path: "scheduled-tasks-seen.json") }
    public var safetyBackupRoot: URL { root.appending(path: "safety-backup", directoryHint: .isDirectory) }

    public func signInDir(_ account: String) -> URL {
        root.appending(path: "accounts").appending(path: account, directoryHint: .isDirectory)
    }

    public func hasSignIn(_ account: String) -> Bool {
        FileManager.default.fileExists(atPath: signInDir(account).appending(path: "config.json").path)
    }

    public func loadState() -> SwitcherState {
        guard let data = try? Data(contentsOf: stateURL) else { return SwitcherState() }
        return (try? Self.decoder.decode(SwitcherState.self, from: data)) ?? SwitcherState()
    }

    public func save(_ state: SwitcherState) throws {
        try Files.writeAtomically(Self.encoder.encode(state), to: stateURL)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// What a switch did, for the activity list.
public struct SwitchReport: Sendable, Equatable {
    public var chats = 0
    public var projects = 0
    public var projectsError: String?
    public var settingsMirrored = false
    public var settingsRestored = false
    /// Chats the switch cut off mid-turn; Claude continues them in the new account.
    public var cutOff: [CutOffTurns.Chat] = []
}

/// The file work of a switch. Every method runs while Claude is closed and
/// puts Claude's files back as they were when a step fails.
public struct SwitchEngine: Sendable {
    public let desktop: ClaudeDesktop
    public let store: Store
    /// Conversations that had a running Claude Code process when Claude quit.
    public var liveConversations = LiveConversations()

    public init(desktop: ClaudeDesktop = .standard, store: Store = .standard) {
        self.desktop = desktop
        self.store = store
    }

    /// Signs Claude in as `target`, keeping the current sign-in. With
    /// `mirrorSettings`, the per-account Claude Code settings of the account
    /// being left (found in `accounts`) are copied onto `target`.
    /// With `org`, Claude opens that workspace of `target`. The held chats
    /// `held` (see `holdChats`) continue there too.
    public func switchFiles(to target: Account, org: String? = nil, accounts: [Account] = [], mirrorSettings: Bool = false,
                            held: [String] = []) throws -> SwitchReport {
        try withBackup { active in
            guard active != target.id else { return SwitchReport() }
            guard store.hasSignIn(target.id) else { throw SwitchError.noSavedSignIn }
            let cutOff = try markCutOffTurns(active, accounts)
            if let active { try save(active) }
            try desktop.restoreSignIn(from: store.signInDir(target.id))
            var target = target
            if let org, org != target.org {
                try ClaudeWeb.setActiveOrg(org, in: desktop.cookieFiles[0])
                target.org = org
            }
            if let left = accounts.first(where: { $0.id == active }) { try carryScheduledTasks(from: left, to: target) }
            var report = try importChats(into: target)
            report.settingsRestored = try AccountPrefs.restore(in: desktop, account: target.id, from: store.signInDir(target.id))
            report.cutOff = try withHeld(held, cutOff, in: target)
            if mirrorSettings, let source = accounts.first(where: { $0.id == active }) {
                report.settingsMirrored = try SettingsMirror.mirror(in: desktop, from: source, to: target)
            }
            return report
        }
    }

    /// Opens another workspace of the signed-in account (personal or Team):
    /// Claude starts in it and signs itself in there. Chats of every account
    /// come along, and what the quit cut off continues, with the held chats `held`.
    public func switchOrg(to org: String, accounts: [Account], held: [String] = []) throws -> SwitchReport {
        try withBackup { active in
            guard var account = accounts.first(where: { $0.id == active }) else { throw SwitchError.noSavedSignIn }
            let cutOff = try markCutOffTurns(active, accounts)
            try ClaudeWeb.setActiveOrg(org, in: desktop.cookieFiles[0])
            let left = account
            account.org = org
            try carryScheduledTasks(from: left, to: account)
            var report = try importChats(into: account)
            report.cutOff = try withHeld(held, cutOff, in: account)
            return report
        }
    }

    /// What the quit cut off, then the held chats `held`, marked to continue
    /// in `account` once its chats are there.
    private func withHeld(_ held: [String], _ cutOff: [CutOffTurns.Chat], in account: Account) throws -> [CutOffTurns.Chat] {
        guard !held.isEmpty else { return cutOff }
        let marked = try CutOffTurns.mark(ids: held, desktop: desktop, account: account.id, org: account.org)
        return cutOff + marked.filter { h in !cutOff.contains { $0.id == h.id } }
    }

    /// Keeps the current sign-in and leaves Claude on its sign-in screen.
    /// Returns the chats a quit cut off, which the new account continues.
    public func prepareAdd(accounts: [Account] = []) throws -> [CutOffTurns.Chat] {
        try withBackup { active in
            let cutOff = try markCutOffTurns(active, accounts)
            if let active { try save(active) }
            try desktop.clearSignIn()
            return cutOff
        }
    }

    /// Chats of the account being left that the quit cut off mid-turn.
    private func markCutOffTurns(_ active: String?, _ accounts: [Account]) throws -> [CutOffTurns.Chat] {
        guard let account = accounts.first(where: { $0.id == active }) else { return [] }
        return try CutOffTurns.mark(desktop: desktop, account: account.id, org: account.org, live: liveConversations)
    }

    /// Keeps the chats a restart would continue waiting instead (see
    /// `ChatSync.holdResumes`). Runs right after a change, Claude closed.
    public func holdChats() throws -> [String] {
        try ChatSync.holdResumes(root: desktop.sessionsRoot)
    }

    /// Continues the held chats `ids`, and whatever this quit cut off, in the
    /// signed-in `account`: brings every chat into it and marks them.
    public func continueHeld(_ ids: [String], accounts: [Account]) throws -> SwitchReport {
        try withBackup { active in
            guard let account = accounts.first(where: { $0.id == active }) else { throw SwitchError.noSavedSignIn }
            let cutOff = try markCutOffTurns(active, accounts)
            var report = try importChats(into: account)
            report.cutOff = try withHeld(ids, cutOff, in: account)
            return report
        }
    }

    /// Saves the sign-in Claude has now, so it can be switched back to.
    public func saveCurrentSignIn() throws {
        guard let active = try desktop.activeAccount() else { return }
        try save(active)
    }

    /// The account's sign-in and a copy of its own settings, which Claude
    /// drops once it sees the account signed out.
    private func save(_ account: String) throws {
        try desktop.saveSignIn(to: store.signInDir(account))
        try AccountPrefs.capture(in: desktop, account: account, into: store.signInDir(account))
    }

    /// Makes the chats and projects of all accounts visible in `account`.
    /// With `mirrorFrom`, that account's per-account Claude Code settings are
    /// copied onto `account` too, as after adding a new account.
    public func importChats(into account: Account, mirrorFrom source: Account? = nil) throws -> SwitchReport {
        var report = SwitchReport()
        if let source {
            report.settingsMirrored = try SettingsMirror.mirror(in: desktop, from: source, to: account)
        }
        report.chats = try ChatSync.sessions(root: desktop.sessionsRoot, account: account.id, org: account.org)
        // A failure here only costs the grouping into projects.
        do {
            report.projects = try ChatSync.spaces(
                root: desktop.spacesRoot, account: account.id, org: account.org, seenURL: store.spacesSeenURL)
        } catch {
            report.projectsError = error.localizedDescription
        }
        return report
    }

    /// Scheduled tasks of the chats and of Cowork follow the switch.
    private func carryScheduledTasks(from left: Account, to target: Account) throws {
        for root in [desktop.sessionsRoot, desktop.spacesRoot] {
            try ChatSync.scheduledTasks(root: root, from: (left.id, left.org), to: (target.id, target.org), seenURL: store.scheduledSeenURL)
        }
    }

    private func withBackup<R>(_ change: (String?) throws -> R) throws -> R {
        try safetyBackupOnce()
        let backup = try desktop.backup(into: store.backupsRoot)
        do {
            return try change(desktop.activeAccount())
        } catch {
            try? desktop.restore(backup: backup)
            throw error
        }
    }

    /// Before the very first change, a copy of everything a switch can touch.
    func safetyBackupOnce() throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: store.safetyBackupRoot.path) else { return }
        let tmp = store.root.appending(path: ".safety-backup-tmp", directoryHint: .isDirectory)
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let items = [desktop.sessionsRoot, desktop.spacesRoot] + desktop.switchedFiles
        for item in items where fm.fileExists(atPath: item.path) {
            try fm.copyItem(at: item, to: tmp.appending(path: item.lastPathComponent))
        }
        try fm.moveItem(at: tmp, to: store.safetyBackupRoot)
    }
}
