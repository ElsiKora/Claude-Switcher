public import Foundation

/// An account's limits over the last hours, from each usage check, for how
/// fast they are being used.
public struct UsageHistory: Codable, Sendable, Equatable {
    public struct Reading: Codable, Sendable, Equatable {
        public var date: Date
        public var session: Double
        public var weekly: Double
    }

    public var readings: [Reading] = []

    public init() {}

    /// Long enough for the weekly rate; older readings are dropped.
    static let keep: TimeInterval = 8 * 3600

    public mutating func add(_ usage: Usage) {
        guard readings.last.map({ usage.checkedAt > $0.date }) ?? true else { return }
        readings.append(Reading(date: usage.checkedAt, session: usage.session, weekly: usage.weekly))
        let cutoff = usage.checkedAt.addingTimeInterval(-Self.keep)
        readings.removeAll { $0.date < cutoff }
    }

    /// Percent per hour one limit has been rising over the last `window`,
    /// counted from its last reset inside the window. Nil without at least
    /// ten minutes of readings.
    public func rate(_ limit: KeyPath<Reading, Double>, over window: TimeInterval, now: Date) -> Double? {
        var recent = readings.filter { now.timeIntervalSince($0.date) <= window }
        if let drop = recent.indices.dropFirst().last(where: { recent[$0][keyPath: limit] + 1 < recent[$0 - 1][keyPath: limit] }) {
            recent = Array(recent[drop...])
        }
        guard let first = recent.first, let last = recent.last else { return nil }
        let hours = last.date.timeIntervalSince(first.date) / 3600
        guard hours >= 10.0 / 60 else { return nil }
        return max(0, (last[keyPath: limit] - first[keyPath: limit]) / hours)
    }
}

/// When an account's limits run out at the pace they are being used.
public struct Forecast: Sendable, Equatable {
    /// When the 5-hour limit reaches 100%, if before it resets.
    public var session: Date?
    /// When the weekly limit reaches 100%, if before it resets.
    public var weekly: Date?
    /// Percent per hour.
    public var sessionRate: Double?
    public var weeklyRate: Double?

    /// The 5-hour limit's pace over half an hour, the week's over three hours.
    public static let sessionWindow: TimeInterval = 30 * 60
    public static let weeklyWindow: TimeInterval = 3 * 3600

    public init(usage: Usage, history: UsageHistory?, now: Date) {
        let u = usage.current(at: now)
        sessionRate = history?.rate(\.session, over: Self.sessionWindow, now: now)
        weeklyRate = history?.rate(\.weekly, over: Self.weeklyWindow, now: now)
        session = Self.runsOut(u.session, rate: sessionRate, reset: u.sessionReset, now: now)
        weekly = Self.runsOut(u.weekly, rate: weeklyRate, reset: u.weeklyReset, now: now)
    }

    static func runsOut(_ percent: Double, rate: Double?, reset: Date?, now: Date) -> Date? {
        guard let rate, rate >= 0.5 else { return nil }
        let at = now.addingTimeInterval(max(0, 100 - percent) / rate * 3600)
        if let reset, at >= reset { return nil }
        return at
    }

    /// The limit that runs out first, and when.
    public var first: (date: Date, weekly: Bool)? {
        switch (session, weekly) {
        case let (s?, w?): w < s ? (w, true) : (s, false)
        case let (s?, nil): (s, false)
        case let (nil, w?): (w, true)
        case (nil, nil): nil
        }
    }

    /// The highest limit `ahead` from now at this pace.
    public func peak(of usage: Usage, in ahead: TimeInterval, now: Date) -> Double {
        let u = usage.current(at: now)
        let hours = ahead / 3600
        return max(u.session + (sessionRate ?? 0) * hours, u.weekly + (weeklyRate ?? 0) * hours)
    }
}

/// What a switch costs: every chat Claude Code has open reads its whole
/// context again in the new account, whose prompt cache starts empty. Priced
/// as cache writes at API prices, from each chat's last reply.
public enum SwitchCost {
    public static func estimate(conversations: Set<String>, projects: URL) -> Double {
        var total = 0.0
        for id in conversations {
            guard let transcript = CutOffTurns.transcript(id, in: projects),
                  let (model, context) = lastContext(transcript),
                  let cost = Pricing.cost(model: model, input: 0, output: 0, cacheRead: 0, cacheWrite5m: context, cacheWrite1h: 0)
            else { continue }
            total += cost
        }
        return total
    }

    /// The model and prompt size of a transcript's last reply, from its tail.
    static func lastContext(_ url: URL) -> (String, Int)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 200_000 ? size - 200_000 : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let message = record["message"] as? [String: Any], let model = message["model"] as? String,
                  let usage = message["usage"] as? [String: Any] else { continue }
            let context = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
                .reduce(0) { $0 + (usage[$1] as? Int ?? 0) }
            return (model, context)
        }
        return nil
    }
}
