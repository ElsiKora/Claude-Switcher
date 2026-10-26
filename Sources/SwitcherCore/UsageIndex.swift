public import Foundation

/// Token counts of a set of messages.
public struct Tokens: Codable, Sendable, Equatable {
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var write5m = 0
    public var write1h = 0
    public var messages = 0

    public init() {}

    public var total: Int { input + output + cacheRead + write5m + write1h }

    public static func + (a: Tokens, b: Tokens) -> Tokens {
        var t = a
        t.input += b.input
        t.output += b.output
        t.cacheRead += b.cacheRead
        t.write5m += b.write5m
        t.write1h += b.write1h
        t.messages += b.messages
        return t
    }
}

/// A quarter of an hour of one model's use in one conversation. A quarter,
/// not an hour, so a switch mid-hour counts each side for its own account.
public struct UsageBucket: Codable, Sendable, Hashable {
    public static let length: TimeInterval = 15 * 60

    /// Quarter hours since 1970.
    public var slot: Int
    public var model: String
    public var fast: Bool
    /// Requests priced as long prompts (`Pricing.isLongPrompt`).
    public var longPrompt: Bool
    /// The Claude Code conversation (the transcript's session id; a
    /// subagent's work counts for the conversation that ran it).
    public var conversation: String

    public init(slot: Int, model: String, fast: Bool, longPrompt: Bool, conversation: String) {
        self.slot = slot
        self.model = model
        self.fast = fast
        self.longPrompt = longPrompt
        self.conversation = conversation
    }

    public static func slot(_ date: Date) -> Int { Int(date.timeIntervalSince1970 / length) }

    public var date: Date { Date(timeIntervalSince1970: Double(slot) * Self.length) }
}

/// Reads token usage out of the Claude Code transcripts in
/// `~/.claude/projects`, the same records Claude Code writes for every
/// reply, and keeps it in a cache so later reads only parse what was added.
/// A reply streamed as several records is counted once, by its message id.
public actor UsageIndex {
    struct FileState: Codable {
        var size: Int64
        var offset: Int64
        var recent: [String]
        var buckets: [UsageBucket: Tokens]
    }

    struct Cache: Codable {
        var version = 3
        var files: [String: FileState] = [:]
    }

    let projects: URL
    let cacheURL: URL
    private var cache: Cache
    private var loaded = false

    /// Where Claude Code keeps its transcripts.
    public static let defaultProjects = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects")

    public init(projects: URL = UsageIndex.defaultProjects, cacheURL: URL) {
        self.projects = projects
        self.cacheURL = cacheURL
        cache = Cache()
    }

    /// Brings the index up to date and returns every bucket. `progress`
    /// gets the bytes read so far and the bytes to read.
    public func refresh(progress: @Sendable (Int64, Int64) -> Void = { _, _ in }) -> [UsageBucket: Tokens] {
        if !loaded {
            loaded = true
            if let data = try? Data(contentsOf: cacheURL), let c = try? JSONDecoder().decode(Cache.self, from: data), c.version == Cache().version {
                cache = c
            }
        }
        let files = transcripts()
        var todo: [(String, Int64)] = []
        var pending: Int64 = 0
        for (path, size) in files {
            let start = cache.files[path].map { $0.size <= size ? $0.offset : 0 } ?? 0
            if size > start { todo.append((path, size)); pending += size - start }
        }
        var done: Int64 = 0
        for (path, size) in todo {
            var state = cache.files[path].flatMap { $0.size <= size ? $0 : nil } ?? FileState(size: 0, offset: 0, recent: [], buckets: [:])
            let before = state.offset
            read(path, into: &state)
            state.size = size
            cache.files[path] = state
            done += size - before
            progress(done, pending)
        }
        // Transcripts that are gone no longer count.
        let present = Set(files.map(\.0))
        cache.files = cache.files.filter { present.contains($0.key) }
        if !todo.isEmpty, let data = try? JSONEncoder().encode(cache) {
            try? Files.writeAtomically(data, to: cacheURL)
        }
        var all: [UsageBucket: Tokens] = [:]
        for state in cache.files.values {
            for (bucket, tokens) in state.buckets { all[bucket, default: Tokens()] = all[bucket, default: Tokens()] + tokens }
        }
        return all
    }

    func transcripts() -> [(String, Int64)] {
        guard let walker = FileManager.default.enumerator(at: projects, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return [] }
        var out: [(String, Int64)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            out.append((url.resolvingSymlinksInPath().path, size))
        }
        return out
    }

    /// The conversation a transcript belongs to: its own name, or for a
    /// subagent's transcript (`<session>/subagents/…`) the session folder.
    func conversation(of path: String) -> String {
        let root = projects.resolvingSymlinksInPath().path
        let relative = path.dropFirst(root.count + 1).split(separator: "/")
        if relative.count >= 3 { return String(relative[1]) }
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    /// Parses complete lines from the saved offset on.
    func read(_ path: String, into state: inout FileState) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(state.offset))
        guard let data = try? handle.readToEnd(), !data.isEmpty,
              let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let conversation = conversation(of: path)
        var recent = state.recent
        var recentSet = Set(recent)
        let assistant = Data("\"type\":\"assistant\"".utf8)
        for line in data[...lastNewline].split(separator: UInt8(ascii: "\n")) {
            guard line.range(of: assistant) != nil,
                  let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let message = record["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let model = message["model"] as? String, model.hasPrefix("claude"),
                  let stamp = record["timestamp"] as? String, let date = AnthropicAPI.date(stamp) else { continue }
            let id = message["id"] as? String ?? UUID().uuidString
            guard recentSet.insert(id).inserted else { continue }
            recent.append(id)
            if recent.count > 400 { recentSet.remove(recent.removeFirst()) }

            var t = Tokens()
            t.messages = 1
            t.input = usage["input_tokens"] as? Int ?? 0
            t.output = usage["output_tokens"] as? Int ?? 0
            t.cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
            let writes = usage["cache_creation_input_tokens"] as? Int ?? 0
            let split = usage["cache_creation"] as? [String: Any]
            t.write1h = min(split?["ephemeral_1h_input_tokens"] as? Int ?? 0, writes)
            t.write5m = writes - t.write1h
            let bucket = UsageBucket(slot: UsageBucket.slot(date), model: model,
                                     fast: usage["speed"] as? String == "fast",
                                     longPrompt: Pricing.isLongPrompt(model: model, promptTokens: t.input + t.cacheRead + writes),
                                     conversation: conversation)
            state.buckets[bucket, default: Tokens()] = state.buckets[bucket, default: Tokens()] + t
        }
        state.recent = recent
        state.offset += Int64(lastNewline - data.startIndex + 1)
    }
}
