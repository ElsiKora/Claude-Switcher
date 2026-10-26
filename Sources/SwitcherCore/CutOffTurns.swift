public import Foundation

/// After a quit, decides which chats Claude should continue and marks them
/// the way Claude itself marks chats on a clean quit. Claude then sends each
/// marked chat "The app was quit while you were working. Please continue
/// from where you left off." when it starts again (four right away, the
/// others when they are opened).
///
/// A chat was cut off when its Claude Code process ran at the quit and
/// either its last turn still waited on the model or a tool, however long
/// that tool had run, or its turn had ended while work it started in the
/// background went on: a shell command or Monitor (a child shell of the
/// process) or a background agent or workflow (launched in the transcript
/// by this process, with no completion notification after it). Side sessions are not marked themselves: the main chat that started
/// them is, so it checks on its sessions and continues them, the way the
/// person would after a restart. A cut-off chat without a main chat is
/// marked itself. Claude did not mark any chat on the first real run, so the
/// switcher does not rely on its own marks.
public enum CutOffTurns {
    /// Claude continues marked chats for a day; older turns stay as they are.
    static let window: TimeInterval = 24 * 3600

    public struct Chat: Sendable, Equatable {
        public var id: String
        public var title: String
        /// Side sessions under this chat that were cut off too.
        public var sideSessions: Int
    }

    struct Entry {
        var url: URL
        var object: JSONObjectText
        var id: String
        var parent: String?
        var cli: String?
        var lastActivity: Int64
        var archived: Bool
    }

    /// Marks the main chats of `account/org` that a quit cut off or whose side
    /// sessions it cut off. Claude must be closed. Returns the marked chats,
    /// most recently active first, the order Claude continues them in.
    @discardableResult
    public static func mark(desktop: ClaudeDesktop, account: String, org: String, live: LiveConversations,
                            projects: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects"),
                            now: Date = .now) throws -> [Chat] {
        let dir = desktop.sessionsRoot.appending(path: account).appending(path: org)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var entries: [String: Entry] = [:]
        for name in names where name.hasPrefix("local_") && name.hasSuffix(".json") {
            let url = dir.appending(path: name)
            guard let object = try? JSONObjectText(contentsOf: url) else { continue }
            let id = String(name.dropLast(".json".count))
            let parent = object.raw("spawnedFrom")
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["sessionId"] as? String
            entries[id] = Entry(
                url: url, object: object, id: id, parent: parent, cli: object.string("cliSessionId"),
                lastActivity: object.raw("lastActivityAt").flatMap { Int64(String(decoding: $0, as: UTF8.self)) } ?? 0,
                archived: object.raw("isArchived").map { String(decoding: $0, as: UTF8.self) } == "true")
        }

        func cutOff(_ e: Entry) -> Bool {
            guard !e.archived, let cli = e.cli, live.ids.contains(cli) else { return false }
            if live.runningCommands.contains(cli) { return true }
            guard let transcript = transcript(cli, in: projects) else { return false }
            if let since = inFlightSince(transcript), now.timeIntervalSince(since) < window { return true }
            return backgroundTasksRunning(transcript, since: live.startedAt[cli] ?? now)
        }
        /// The main chat at the top of a chat's chain of side sessions.
        func main(_ id: String) -> String {
            var current = id
            var seen: Set<String> = [id]
            while let parent = entries[current]?.parent, let up = entries[parent], !up.archived, seen.insert(parent).inserted {
                current = parent
            }
            return current
        }

        var cutUnder: [String: Int] = [:]
        for e in entries.values where cutOff(e) {
            let top = main(e.id)
            cutUnder[top, default: 0] += top == e.id ? 0 : 1
        }

        var marked: [(Int64, Chat)] = []
        for (id, sides) in cutUnder {
            guard var e = entries[id] else { continue }
            let chat = Chat(id: String(id.dropFirst("local_".count)), title: e.object.string("title") ?? "", sideSessions: sides)
            if !e.object.contains("interruptedByQuitAt") {
                let modified = try? e.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                try e.object.set("interruptedByQuitAt", raw: Data(String(Int64(now.timeIntervalSince1970 * 1000)).utf8))
                try e.object.set("interruptedAwaitingPerson", raw: Data("false".utf8))
                try Files.writeAtomically(e.object.data, to: e.url, modified: modified)
            }
            marked.append((e.lastActivity, chat))
        }
        return marked.sorted { $0.0 > $1.0 }.map(\.1)
    }

    /// Marks the chats `ids` of `account/org` to continue, as `mark` does,
    /// for chats that were held while several accounts were added. Claude
    /// must be closed. Returns them most recently active first.
    public static func mark(ids: [String], desktop: ClaudeDesktop, account: String, org: String, now: Date = .now) throws -> [Chat] {
        let dir = desktop.sessionsRoot.appending(path: account).appending(path: org)
        var marked: [(Int64, Chat)] = []
        for id in ids {
            let url = dir.appending(path: "local_\(id).json")
            guard var object = try? JSONObjectText(contentsOf: url) else { continue }
            if object.raw("isArchived").map({ String(decoding: $0, as: UTF8.self) }) == "true" { continue }
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if !object.contains("interruptedByQuitAt") {
                try object.set("interruptedByQuitAt", raw: Data(String(Int64(now.timeIntervalSince1970 * 1000)).utf8))
                try object.set("interruptedAwaitingPerson", raw: Data("false".utf8))
                try Files.writeAtomically(object.data, to: url, modified: modified)
            }
            let last = object.raw("lastActivityAt").flatMap { Int64(String(decoding: $0, as: UTF8.self)) } ?? 0
            marked.append((last, Chat(id: id, title: object.string("title") ?? "", sideSessions: 0)))
        }
        return marked.sorted { $0.0 > $1.0 }.map(\.1)
    }

    static func transcript(_ cliSessionID: String, in projects: URL) -> URL? {
        for dir in Files.subdirectories(of: projects) {
            let url = dir.appending(path: "\(cliSessionID).jsonl")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Whether the conversation launched a background agent or workflow
    /// since `since` that has not reported back with a task notification.
    /// Background shell commands are seen as processes instead.
    static func backgroundTasksRunning(_ transcript: URL, since: Date) -> Bool {
        guard let data = try? Data(contentsOf: transcript, options: .mappedIfSafe) else { return false }
        var launched: Set<String> = []
        var reported: Set<String> = []
        let notification = Data("<task-notification>".utf8)
        let launch = Data("\"async_launched\"".utf8)
        // Most chats never launch one; the whole file is skipped then.
        guard let first = data.range(of: launch) else { return false }
        let start = data[..<first.lowerBound].lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? data.startIndex
        for line in data[start...].split(separator: UInt8(ascii: "\n")) {
            let isLaunch = line.range(of: launch) != nil
            let isReport = line.range(of: notification) != nil
            guard isLaunch || isReport,
                  let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if isReport {
                let text = String(decoding: line, as: UTF8.self)
                for match in text.matches(of: /<task-id>([^<]+)<\/task-id>/) { reported.insert(String(match.1)) }
            }
            guard isLaunch, record["isSidechain"] as? Bool != true,
                  let result = record["toolUseResult"] as? [String: Any], result["status"] as? String == "async_launched",
                  let id = (result["agentId"] ?? result["taskId"]) as? String,
                  let at = (record["timestamp"] as? String).flatMap(AnthropicAPI.date), at >= since
            else { continue }
            launched.insert(id)
        }
        return !launched.subtracting(reported).isEmpty
    }

    /// When the last turn of a conversation started waiting for the model or
    /// a tool, nil when its last turn finished.
    static func inFlightSince(_ transcript: URL) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: transcript) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 524_288 ? size - 524_288 : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        let lines = data.split(separator: UInt8(ascii: "\n"))
        for line in lines.reversed() {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = record["type"] as? String, type == "user" || type == "assistant",
                  record["isSidechain"] as? Bool != true, record["isMeta"] as? Bool != true
            else { continue }
            let at = (record["timestamp"] as? String).flatMap(AnthropicAPI.date) ?? .distantPast
            let message = record["message"] as? [String: Any] ?? [:]
            if type == "user" { return at }
            switch message["stop_reason"] as? String {
            case "end_turn", "stop_sequence", "max_tokens", "refusal": return nil
            default: return at
            }
        }
        return nil
    }
}
