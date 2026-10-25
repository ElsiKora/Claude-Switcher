public import Foundation

/// Claude lists Claude Code chats from `claude-code-sessions/<account>/<org>/`,
/// one `local_<id>.json` per chat. The conversations themselves live in
/// `~/.claude/projects` and are shared by all accounts, so a chat shows up in
/// another account once its entry file is there. A `deleted_<id>` file marks
/// a chat the user deleted; such chats are never copied back.
public enum ChatSync {
    /// Copies chat entries of every other account into `account/org`. Adds
    /// missing chats and refreshes older copies, never deletes. Returns how
    /// many entries it wrote.
    @discardableResult
    public static func sessions(root: URL, account: String, org: String) throws -> Int {
        let target = root.appending(path: account).appending(path: org, directoryHint: .isDirectory)
        var deleted: Set<String> = []
        var sources: [URL] = []
        for accountDir in Files.subdirectories(of: root) {
            for dir in Files.subdirectories(of: accountDir) {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
                let isTarget = dir.standardizedFileURL.path == target.standardizedFileURL.path
                for name in names {
                    if name.hasPrefix("deleted_") {
                        deleted.insert(String(name.dropFirst("deleted_".count)))
                    } else if name.hasPrefix("local_"), name.hasSuffix(".json"), !isTarget {
                        sources.append(dir.appending(path: name))
                    }
                }
            }
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var written = 0
        for src in sources {
            let name = src.lastPathComponent
            let id = String(name.dropFirst("local_".count).dropLast(".json".count))
            guard !deleted.contains(id) else { continue }
            let dst = target.appending(path: name)
            guard let source = Entry(src) else { continue }
            let existing = Entry(dst)
            if let existing {
                // A turn cut off by the quit moves along even when the entry is not newer.
                let carriesResume = source.isInterrupted && !existing.isInterrupted && source.lastActivity >= existing.lastActivity
                guard source.lastActivity > existing.lastActivity || carriesResume else { continue }
            } else if FileManager.default.fileExists(atPath: dst.path) {
                continue // A file Claude cannot read either is left to Claude.
            }
            var copy = source.object
            // Connector ids belong to the account that made them; Claude fills
            // in the target account's own connectors when the chat starts.
            if copy.contains("remoteMcpServersConfig") { try copy.set("remoteMcpServersConfig", raw: Data("[]".utf8)) }
            // Keep the dates, so the copy does not look like a chat at work.
            try Files.writeAtomically(copy.data, to: dst, modified: source.modified)
            if source.isInterrupted {
                // Claude continues a turn the quit cut off in the account it
                // starts with. Only one copy may carry that, or switching back
                // would send a second "continue" into the same conversation.
                var cleared = source.object
                for key in resumeKeys { try cleared.remove(key) }
                try Files.writeAtomically(cleared.data, to: src, modified: source.modified)
            }
            written += 1
        }
        return written
    }

    /// What Claude writes into a chat entry when a quit cuts off its turn.
    static let resumeKeys = ["interruptedByQuitAt", "interruptedAwaitingPerson", "interruptedUnseenResume"]

    struct Entry {
        var object: JSONObjectText
        var lastActivity: Int64
        var isInterrupted: Bool
        var modified: Date?

        init?(_ url: URL) {
            guard let data = try? Data(contentsOf: url), let object = try? JSONObjectText(data: data) else { return nil }
            self.object = object
            modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            lastActivity = object.raw("lastActivityAt").flatMap { Int64(String(decoding: $0, as: UTF8.self)) } ?? 0
            let at = object.raw("interruptedByQuitAt").map { String(decoding: $0, as: UTF8.self) }
            isInterrupted = at != nil && at != "null"
        }
    }

    /// When anyone last worked in a chat: the newest write to the chat
    /// lists in `root` or to a Claude Code transcript in `projects`. Claude
    /// leaves a chat's list entry alone during a long reply, but Claude Code
    /// appends every record of it (subagents included) to the transcript.
    public static func lastChatActivity(root: URL, projects: URL) -> Date? {
        [lastChatWrite(root: root), lastTranscriptWrite(projects: projects)].compactMap(\.self).max()
    }

    /// When a transcript under `projects` was last written.
    public static func lastTranscriptWrite(projects: URL) -> Date? {
        guard let walker = FileManager.default.enumerator(at: projects, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return nil
        }
        var last: Date?
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            if let d = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               last.map({ d > $0 }) ?? true {
                last = d
            }
        }
        return last
    }

    /// When any chat entry was last written.
    public static func lastChatWrite(root: URL) -> Date? {
        var last: Date?
        for accountDir in Files.subdirectories(of: root) {
            for dir in Files.subdirectories(of: accountDir) {
                let items = (try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                for item in items where item.lastPathComponent.hasPrefix("local_") {
                    if let d = try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                       last.map({ d > $0 }) ?? true {
                        last = d
                    }
                }
            }
        }
        return last
    }

    // MARK: - Projects

    /// `projects` and `migration` tie a project to claude.ai projects of the
    /// organization that made it. Another organization cannot open those, so
    /// a copy leaves them out and Claude sets the project up for its own.
    static let orgBoundKeys = ["projects", "migration"]

    /// Copies the projects of every other account into the target account's
    /// `spaces.json`. Adds missing projects and refreshes older ones, never
    /// deletes. `seenURL` remembers which projects each account had, so a
    /// project the user deleted is not brought back. Returns how many
    /// projects it wrote.
    @discardableResult
    public static func spaces(root: URL, account: String, org: String, seenURL: URL) throws -> Int {
        let targetURL = root.appending(path: account).appending(path: org).appending(path: "spaces.json")
        var newest: [String: [String: Any]] = [:]
        var order: [String] = []
        for accountDir in Files.subdirectories(of: root) {
            for dir in Files.subdirectories(of: accountDir) {
                let url = dir.appending(path: "spaces.json")
                guard url.standardizedFileURL.path != targetURL.standardizedFileURL.path,
                      let (_, list) = try? readSpaces(url) else { continue }
                for space in list {
                    let id = space["id"] as! String
                    if let cur = newest[id] {
                        if updatedAt(space) > updatedAt(cur) { newest[id] = space }
                    } else {
                        order.append(id)
                        newest[id] = space
                    }
                }
            }
        }

        var file: [String: Any]
        var list: [[String: Any]]
        if FileManager.default.fileExists(atPath: targetURL.path) {
            // A file Claude cannot read either is left to Claude's own recovery.
            (file, list) = try readSpaces(targetURL)
        } else {
            (file, list) = ([:], [])
        }

        let key = "\(account)/\(org)"
        var seen = readSeen(seenURL)
        let had = Set(seen[key] ?? [])
        var index: [String: Int] = [:]
        for (i, space) in list.enumerated() { index[space["id"] as! String] = i }

        var written = 0
        for id in order {
            let src = newest[id]!
            if let i = index[id] {
                guard updatedAt(src) > updatedAt(list[i]) else { continue }
                var refreshed = src
                for k in orgBoundKeys { refreshed[k] = list[i][k] }
                list[i] = refreshed
            } else {
                guard !had.contains(id) else { continue }
                var copy = src
                for k in orgBoundKeys { copy[k] = nil }
                list.append(copy)
                index[id] = list.count - 1
            }
            written += 1
        }

        if written > 0 {
            file["spaces"] = list
            let data = try JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try Files.writeAtomically(data, to: targetURL)
        }
        seen[key] = list.map { $0["id"] as! String }
        try writeSeen(seen, to: seenURL)
        return written
    }

    /// The whole file and its projects that carry an id.
    static func readSpaces(_ url: URL) throws -> ([String: Any], [[String: Any]]) {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let file = object as? [String: Any] else { throw JSONTextError.notAnObject }
        let all = file["spaces"] as? [[String: Any]] ?? []
        return (file, all.filter { ($0["id"] as? String).map { !$0.isEmpty } ?? false })
    }

    static func updatedAt(_ space: [String: Any]) -> Double {
        (space["updatedAt"] as? NSNumber)?.doubleValue ?? 0
    }

    static func readSeen(_ url: URL) -> [String: [String]] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: [String]].self, from: data)) ?? [:]
    }

    static func writeSeen(_ seen: [String: [String]], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(seen)
        if (try? Data(contentsOf: url)) == data { return }
        try Files.writeAtomically(data, to: url)
    }
}
