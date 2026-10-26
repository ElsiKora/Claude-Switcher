public import AppKit
import Darwin

/// What Claude Code was running when Claude quit.
public struct LiveConversations: Sendable, Equatable {
    /// Conversations with a running Claude Code process.
    public var ids: Set<String> = []
    /// Of those, the ones running a shell command at that moment.
    public var runningCommands: Set<String> = []
    /// When each process started; a background agent launched before that
    /// belonged to an earlier process and is not running.
    public var startedAt: [String: Date] = [:]

    public init(ids: Set<String> = [], runningCommands: Set<String> = [], startedAt: [String: Date] = [:]) {
        self.ids = ids
        self.runningCommands = runningCommands
        self.startedAt = startedAt
    }
}

/// Quits and starts the Claude desktop app.
@MainActor
public enum ClaudeProcess {
    static var running: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: ClaudeDesktop.bundleIdentifier)
    }

    public static var isRunning: Bool { !running.isEmpty }

    public static var appURL: URL? {
        running.first?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: ClaudeDesktop.bundleIdentifier)
    }

    /// Closes Claude with its full shutdown, so it saves every chat and marks
    /// the turns it cut off to continue them on the next start. SIGTERM
    /// quits it as its Quit command does: with chats at work it first asks
    /// "Claude is still working", and the switcher answers "Quit anyway"
    /// when macOS lets it (see `QuitPrompt`). The shutdown may take up to
    /// 75 s plus a 15 s watchdog; Claude is only ended by force once all of
    /// it has run out, or when the prompt stays unanswered that long.
    /// Returns what Claude Code was running right before.
    @discardableResult
    public static func quit(desktop: ClaudeDesktop = .standard, grace: Duration = .seconds(100)) async throws -> LiveConversations {
        let apps = running
        guard !apps.isEmpty else { return LiveConversations() }
        let live = liveConversations()
        let title = QuitPrompt.quitAnywayTitle(app: apps.first?.bundleURL, desktop: desktop)
        for app in apps { kill(app.processIdentifier, SIGTERM) }
        if await waitGone(within: grace, answering: apps.map(\.processIdentifier), title: title) { return live }
        for app in running { app.forceTerminate() }
        if await waitGone(within: .seconds(10)) { return live }
        throw SwitchError.claudeDidNotQuit
    }

    /// Waits for Claude and its helpers to be gone, pressing `title` in its
    /// quit prompt for `pids` once the prompt shows.
    private static func waitGone(within timeout: Duration, answering pids: [pid_t] = [], title: String = "") async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var answered = pids.isEmpty
        var nextLook = clock.now
        while clock.now < deadline {
            if running.allSatisfy(\.isTerminated) || running.isEmpty {
                // The helpers hold the cookie store until they are gone too.
                while helpersRunning(), clock.now < deadline + .seconds(10) {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                return true
            }
            if !answered, clock.now >= nextLook, QuitPrompt.isAllowed {
                answered = pids.contains { QuitPrompt.answer(pid: $0, title: title) }
                nextLook = clock.now + .seconds(1)
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    /// Whether any process still runs from inside Claude.app, such as its
    /// helpers or the network service that holds the cookie store.
    nonisolated static func helpersRunning() -> Bool {
        guard let bundle = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ClaudeDesktop.bundleIdentifier) else {
            return false
        }
        let prefix = bundle.resolvingSymlinksInPath().path + "/"
        var pids = [pid_t](repeating: 0, count: 4096)
        let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return false }
        var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(bytes)) where pid > 0 {
            let n = proc_pidpath(pid, &path, UInt32(path.count))
            if n > 0, String(decoding: path.prefix(Int(n)), as: UTF8.self).hasPrefix(prefix) { return true }
        }
        return false
    }

    /// The Claude Code processes Claude runs for its chats, by conversation
    /// id (`--resume=<id>`), and which of them run a shell command. A chat
    /// whose process is alive is at work or ready for the next message; one
    /// without a process is asleep. Claude Code runs every command, in the
    /// foreground or the background, as a child shell that sources its shell
    /// snapshot, so a chat that ended its turn with such a child still had a
    /// background command (or a Monitor) running.
    nonisolated public static func liveConversations() -> LiveConversations {
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return LiveConversations() }
        var result = LiveConversations()
        var conversationOf: [pid_t: String] = [:]
        var shells: [pid_t] = []
        for pid in pids.prefix(Int(count)) where pid > 0 {
            let args = arguments(of: pid)
            guard let exe = args.first else { continue }
            if exe.hasSuffix("/claude.app/Contents/MacOS/claude"), exe.contains("/Application Support/Claude/claude-code/") {
                if let id = conversation(in: args) {
                    result.ids.insert(id)
                    conversationOf[pid] = id
                    if let info = bsdInfo(of: pid) {
                        result.startedAt[id] = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
                    }
                }
            } else if args.count >= 3, args[1] == "-c", args[2].contains("/.claude/shell-snapshots/snapshot-") {
                shells.append(pid)
            }
        }
        for shell in shells {
            if let parent = parentPID(of: shell), let id = conversationOf[parent] { result.runningCommands.insert(id) }
        }
        return result
    }

    nonisolated static func conversation(in args: [String]) -> String? {
        for (i, arg) in args.enumerated() {
            if arg.hasPrefix("--resume=") { return String(arg.dropFirst("--resume=".count)) }
            if arg.hasPrefix("--session-id=") { return String(arg.dropFirst("--session-id=".count)) }
            if arg == "--resume" || arg == "--session-id", i + 1 < args.count { return args[i + 1] }
        }
        return nil
    }

    nonisolated static func parentPID(of pid: pid_t) -> pid_t? {
        bsdInfo(of: pid).map { pid_t($0.pbi_ppid) }
    }

    nonisolated static func bsdInfo(of pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    /// A process's arguments, the executable path first, from KERN_PROCARGS2.
    nonisolated static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var parts: [String] = []
        var i = MemoryLayout<Int32>.size
        // The executable path, then padding, then argc arguments.
        func next() -> String? {
            while i < size, buffer[i] == 0 { i += 1 }
            guard i < size else { return nil }
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            return String(decoding: buffer[start..<i], as: UTF8.self)
        }
        guard let exe = next() else { return [] }
        parts.append(exe)
        for _ in 0..<argc {
            guard let arg = next() else { break }
            parts.append(arg)
        }
        // argv[0] repeats the executable; drop it.
        if parts.count > 1 { parts.remove(at: 1) }
        return parts
    }

    public static func launch(_ url: URL?) async throws {
        guard let url = url ?? appURL else { throw SwitchError.claudeNotInstalled }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}
