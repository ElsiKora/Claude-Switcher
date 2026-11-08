public import Foundation
import CryptoKit

/// Claude lists Claude Code chats from `claude-code-sessions/<account>/<org>/`,
/// one `local_<id>.json` per chat. The conversations themselves live in
/// `~/.claude/projects` and are shared by all accounts, so a chat shows up in
/// another account once its entry file is there. A `deleted_<id>` file marks
/// a chat the user deleted; such chats are never copied back.
public enum ChatSync {
    /// Copies chat entries of every other account into `account/org`. Adds
    /// missing chats and refreshes older copies, never deletes. Of all the
    /// copies of a chat, the latest one (see `Entry.supersedes`) is the one
    /// that goes in, and the target's archived index follows its archive
    /// state. `seenURL` keeps what every chat list held at the last sync
    /// (see `Seen`), which tells the copies that changed since; it is
    /// brought up to date. Claude must be closed. Returns how many entries
    /// it wrote.
    @discardableResult
    public static func sessions(root: URL, account: String, org: String, seenURL: URL) throws -> Int {
        let targetList = "\(account)/\(org)"
        let target = root.appending(path: account).appending(path: org, directoryHint: .isDirectory)
        let seen = Seen(contentsOf: seenURL)
        var now = Seen()
        var deleted: Set<String> = []
        // The target's own copies, and the latest copy of each chat in the
        // other accounts, by chat id.
        var mine: [String: Entry] = [:]
        var latest: [String: (url: URL, entry: Entry)] = [:]
        var order: [String] = []
        for accountDir in Files.subdirectories(of: root) {
            for dir in Files.subdirectories(of: accountDir) {
                let list = "\(accountDir.lastPathComponent)/\(dir.lastPathComponent)"
                for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
                    if name.hasPrefix("deleted_") {
                        deleted.insert(String(name.dropFirst("deleted_".count)))
                        continue
                    }
                    guard name.hasPrefix("local_"), name.hasSuffix(".json") else { continue }
                    let url = dir.appending(path: name)
                    let id = String(name.dropFirst("local_".count).dropLast(".json".count))
                    guard let entry = Entry(url, seen: seen.lists[list]?[id]) else { continue }
                    now.note(entry, id, in: list)
                    if list == targetList {
                        mine[id] = entry
                    } else if let current = latest[id] {
                        if entry.supersedes(current.entry) { latest[id] = (url, entry) }
                    } else {
                        latest[id] = (url, entry)
                        order.append(id)
                    }
                }
            }
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var archived = ArchivedIndex(target.appending(path: ArchivedIndex.fileName))
        var written = 0
        for id in order where !deleted.contains(id) {
            guard let pick = latest[id] else { continue }
            let (src, source) = (pick.url, pick.entry)
            let dst = target.appending(path: src.lastPathComponent)
            if let existing = mine[id] {
                guard source.supersedes(existing) else { continue }
            } else if FileManager.default.fileExists(atPath: dst.path) {
                continue // A file Claude cannot read either is left to Claude.
            }
            var copy = source.object
            // Connector ids belong to the account that made them; Claude fills
            // in the target account's own connectors when the chat starts.
            if copy.contains("remoteMcpServersConfig") { try copy.set("remoteMcpServersConfig", raw: Data("[]".utf8)) }
            // The copy carries the date of the change, so it does not look
            // like a chat at work, and the next sync still sees when the chat
            // last changed.
            try Files.writeAtomically(copy.data, to: dst, modified: source.changedAt)
            now.note(source, id, in: targetList)
            archived?.set("local_\(id)", archived: source.isArchived)
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
        try archived?.save()
        try now.save(to: seenURL)
        return written
    }

    /// Takes the "continue" marks off every chat entry of every account, so
    /// Claude starts without continuing them, and returns the chats that had
    /// one (ids without `local_`), for continuing them later.
    public static func holdResumes(root: URL) throws -> [String] {
        var held: [String] = []
        for accountDir in Files.subdirectories(of: root) {
            for dir in Files.subdirectories(of: accountDir) {
                for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
                where name.hasPrefix("local_") && name.hasSuffix(".json") {
                    let url = dir.appending(path: name)
                    guard let entry = Entry(url), entry.isInterrupted else { continue }
                    var cleared = entry.object
                    for key in resumeKeys { try cleared.remove(key) }
                    try Files.writeAtomically(cleared.data, to: url, modified: entry.modified)
                    let id = String(name.dropFirst("local_".count).dropLast(".json".count))
                    if !held.contains(id) { held.append(id) }
                }
            }
        }
        return held
    }

    // MARK: - Scheduled tasks

    /// Claude keeps scheduled tasks per account and workspace
    /// (`<root>/<account>/<org>/scheduled-tasks.json`) and runs only the
    /// signed-in one's, so a switch carries the tasks of the account being
    /// left into the one switched to. Tasks are matched by `id`: the source's
    /// version wins; a task only the target has stays unless the source once
    /// had it (then it was deleted there, and stays deleted). Returns how many
    /// tasks the target has now, or nil when there was nothing to carry.
    @discardableResult
    public static func scheduledTasks(root: URL, from source: (account: String, org: String),
                                      to target: (account: String, org: String), seenURL: URL) throws -> Int? {
        let name = "scheduled-tasks.json"
        let from = root.appending(path: source.account).appending(path: source.org).appending(path: name)
        let toDir = root.appending(path: target.account).appending(path: target.org, directoryHint: .isDirectory)
        let to = toDir.appending(path: name)
        guard from != to, let data = try? Data(contentsOf: from),
              let theirs = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let sourceTasks = theirs["scheduledTasks"] as? [[String: Any]] ?? []
        let mine = (try? Data(contentsOf: to)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let targetTasks = mine?["scheduledTasks"] as? [[String: Any]] ?? []
        guard !sourceTasks.isEmpty || !targetTasks.isEmpty else { return nil }
        // Without ids there is nothing to match on: leave the target alone.
        guard (sourceTasks + targetTasks).allSatisfy({ $0["id"] is String }) else { return nil }

        var seen = Set((try? JSONDecoder().decode([String].self, from: Data(contentsOf: seenURL))) ?? [])
        let sourceIDs = Set(sourceTasks.compactMap { $0["id"] as? String })
        let kept = targetTasks.filter { t in
            guard let id = t["id"] as? String else { return false }
            return !sourceIDs.contains(id) && !seen.contains(id)
        }
        seen.formUnion(sourceIDs)
        var out = mine ?? theirs
        out["scheduledTasks"] = sourceTasks + kept
        try FileManager.default.createDirectory(at: toDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Files.writeAtomically(JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), to: to)
        try Files.writeAtomically(JSONEncoder().encode(seen.sorted()), to: seenURL)
        return sourceTasks.count + kept.count
    }

    /// What Claude writes into a chat entry when a quit cuts off its turn.
    static let resumeKeys = ["interruptedByQuitAt", "interruptedAwaitingPerson", "interruptedUnseenResume"]

    struct Entry {
        var object: JSONObjectText
        var lastActivity: Int64
        var isInterrupted: Bool
        var isArchived: Bool
        var title: String?
        /// The file date.
        var modified: Date?
        /// When the chat last changed in this copy, as far as a sync can tell.
        var changedAt: Date?

        /// `seen` is the copy as its list held it at the last sync.
        init?(_ url: URL, seen: Seen.Chat? = nil) {
            guard let data = try? Data(contentsOf: url), let object = try? JSONObjectText(data: data) else { return nil }
            self.object = object
            modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            lastActivity = object.raw("lastActivityAt").flatMap { Int64(String(decoding: $0, as: UTF8.self)) } ?? 0
            let at = object.raw("interruptedByQuitAt").map { String(decoding: $0, as: UTF8.self) }
            isInterrupted = at != nil && at != "null"
            let archived = object.raw("isArchived").map { String(decoding: $0, as: UTF8.self) } == "true"
            let title = object.string("title")
            isArchived = archived
            self.title = title
            // Claude rewrites an entry for far more than a change the person
            // made: opening the chat, its connectors, messages between
            // sessions. Each moves the file date. A copy whose archive state
            // and title are as they were at the last sync keeps the date they
            // had then, so a stale copy Claude only rewrote does not pass for
            // the latest. Such copies are in an account switched to in Claude
            // itself: no sync brought its list up to date first.
            if let seen, seen.state == Self.state(archived: archived, title: title) {
                changedAt = seen.changedAt
            } else {
                changedAt = modified
            }
        }

        /// What a person changes in a chat without a new turn, which only a
        /// date can order: whether it is archived, and its title.
        var state: String { Self.state(archived: isArchived, title: title) }

        static func state(archived: Bool, title: String?) -> String {
            let text = (archived ? "archived" : "open") + "\n" + (title ?? "")
            return SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        }

        /// Whether this copy of a chat is later than `other`. More recent
        /// activity wins. At equal activity, a turn the quit cut off wins, so
        /// it moves along and is continued where Claude starts; after that,
        /// the later change wins. Archiving, unarchiving or renaming a chat
        /// rewrites its entry without touching `lastActivityAt`, so
        /// `changedAt` tells which copy changed last; copies carry it as
        /// their file date.
        func supersedes(_ other: Entry) -> Bool {
            if lastActivity != other.lastActivity { return lastActivity > other.lastActivity }
            if isInterrupted != other.isInterrupted { return isInterrupted }
            guard let mine = changedAt, let theirs = other.changedAt else { return false }
            return mine.timeIntervalSince(theirs) > Self.sameChange
        }

        /// Dates this close are the same change: a copy carries its source's
        /// date, which the file system may round.
        static let sameChange: TimeInterval = 1
    }

    /// What every chat list held at the last sync, while Claude was closed
    /// (`chats-seen.json`): for each list (`<account>/<org>`) and chat, the
    /// state of its copy there (`Entry.state`) and when that last changed.
    /// A copy whose state differs from it changed since.
    struct Seen: Codable, Equatable {
        struct Chat: Codable, Equatable {
            var state: String
            var changedAt: Date
        }

        var lists: [String: [String: Chat]] = [:]

        init() {}

        /// Empty when there is no file yet or it cannot be read: then every
        /// copy counts from its file date.
        init(contentsOf url: URL) {
            self = (try? Self.decoder.decode(Seen.self, from: Data(contentsOf: url))) ?? Seen()
        }

        mutating func note(_ entry: Entry, _ id: String, in list: String) {
            guard let changedAt = entry.changedAt else { return }
            lists[list, default: [:]][id] = Chat(state: entry.state, changedAt: changedAt)
        }

        func save(to url: URL) throws {
            let data = try Self.encoder.encode(self)
            if (try? Data(contentsOf: url)) == data { return }
            try Files.writeAtomically(data, to: url)
        }

        static let encoder: JSONEncoder = {
            let e = JSONEncoder()
            e.outputFormatting = [.sortedKeys]
            e.dateEncodingStrategy = .secondsSince1970
            return e
        }()

        static let decoder: JSONDecoder = {
            let d = JSONDecoder()
            d.dateDecodingStrategy = .secondsSince1970
            return d
        }()
    }

    /// A store's `archived-sessions.idx`, `{"v":1,"archived":["local_<id>", …]}`.
    /// Claude keeps it in line with `isArchived` in each entry, so a copied
    /// entry's archive state goes into the target's index too.
    struct ArchivedIndex {
        static let fileName = "archived-sessions.idx"

        let url: URL
        /// The file as Claude wrote it; nil when the store has none yet.
        private var text: JSONObjectText?
        private(set) var ids: [String]
        private var changed = false

        /// Nil for an index that is there but cannot be read: like an entry
        /// Claude cannot read, it is left to Claude.
        init?(_ url: URL) {
            self.url = url
            guard FileManager.default.fileExists(atPath: url.path) else {
                text = nil
                ids = []
                return
            }
            guard let text = try? JSONObjectText(contentsOf: url), let raw = text.raw("archived"),
                  let ids = try? JSONDecoder().decode([String].self, from: raw) else { return nil }
            self.text = text
            self.ids = ids
        }

        /// Adds `name` (`local_<id>`) for an archived chat, removes it for an open one.
        mutating func set(_ name: String, archived: Bool) {
            if archived {
                guard !ids.contains(name) else { return }
                ids.append(name)
                changed = true
            } else if ids.contains(name) {
                ids.removeAll { $0 == name }
                changed = true
            }
        }

        /// Writes the index, through a temporary file, when a chat changed in it.
        func save() throws {
            guard changed else { return }
            let list = try JSONSerialization.data(withJSONObject: ids, options: [.withoutEscapingSlashes])
            let data: Data
            if var text {
                try text.set("archived", raw: list)
                data = text.data
            } else {
                data = Data(#"{"v":1,"archived":"#.utf8) + list + Data("}".utf8)
            }
            try Files.writeAtomically(data, to: url)
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
