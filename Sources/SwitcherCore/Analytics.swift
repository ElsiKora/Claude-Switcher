public import Foundation

/// Which account Claude was signed in to when. Before the first switch the
/// switcher made, each chat counts for the account whose list Claude first
/// kept it in; from then on, for the account signed in at the time.
public struct AccountTimeline: Codable, Sendable, Equatable {
    public struct SignIn: Codable, Sendable, Equatable {
        public var date: Date
        public var account: String?

        public init(date: Date, account: String?) {
            self.date = date
            self.account = account
        }
    }

    public var signIns: [SignIn] = []
    /// Conversation (transcript id) to account, from before the first switch.
    public var native: [String: String] = [:]

    public init() {}

    public func account(at date: Date, conversation: String) -> String? {
        guard let first = signIns.first, date >= first.date else { return native[conversation] }
        return signIns.last { $0.date <= date }?.account
    }

    /// Adds a sign-in unless it repeats the one in effect.
    public mutating func record(_ account: String?, at date: Date) {
        if let last = signIns.last, last.account == account { return }
        signIns.append(SignIn(date: date, account: account))
        signIns.sort { $0.date < $1.date }
    }

    /// The sign-ins the switcher's backups show: each backup was taken at a
    /// restart, with the config of the account signed in until then.
    public static func fromBackups(_ root: URL, current: String?) -> [SignIn] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
        var before: [(Date, String?)] = []
        for name in names {
            guard let date = formatter.date(from: name) else { continue }
            let config = root.appending(path: name).appending(path: "config.json")
            let account = (try? JSONObjectText(contentsOf: config)).flatMap { ClaudeDesktop.signedInAccount(of: $0) }
            before.append((date, account))
        }
        var out: [SignIn] = []
        for (i, (date, _)) in before.enumerated() {
            let next = i + 1 < before.count ? before[i + 1].1 : current
            out.append(SignIn(date: date, account: next))
        }
        return out
    }

    /// Conversation to account for chats Claude kept before any switch, read
    /// from the copy of the chat lists taken before the first change.
    public static func native(from sessionsRoot: URL) -> [String: String] {
        var out: [String: String] = [:]
        for accountDir in Files.subdirectories(of: sessionsRoot) {
            for org in Files.subdirectories(of: accountDir) {
                for name in (try? FileManager.default.contentsOfDirectory(atPath: org.path)) ?? [] where name.hasPrefix("local_") {
                    if let entry = try? JSONObjectText(contentsOf: org.appending(path: name)), let cli = entry.string("cliSessionId") {
                        out[cli] = accountDir.lastPathComponent
                    }
                }
            }
        }
        return out
    }
}

/// Usage summed over a slice of time, with what it would cost at API prices.
public struct UsageTotal: Sendable, Equatable {
    public var tokens = Tokens()
    public var cost: Double = 0
    /// Tokens of models the price table does not know.
    public var unpriced = 0

    public init() {}

    mutating func add(_ t: Tokens, _ bucket: UsageBucket) {
        tokens = tokens + t
        if let c = Pricing.cost(model: bucket.model, input: t.input, output: t.output, cacheRead: t.cacheRead,
                                cacheWrite5m: t.write5m, cacheWrite1h: t.write1h, fast: bucket.fast, longPrompt: bucket.longPrompt) {
            cost += c
        } else {
            unpriced += t.total
        }
    }

    /// Share of input served from the cache.
    public var cacheHitRate: Double {
        let all = tokens.input + tokens.cacheRead + tokens.write5m + tokens.write1h
        return all == 0 ? 0 : Double(tokens.cacheRead) / Double(all)
    }
}

/// Usage broken down for the analytics page.
public struct UsageReport: Sendable {
    public struct Day: Sendable, Identifiable {
        public var id: Date { day }
        public var day: Date
        public var key: String
        public var total: UsageTotal
    }

    public var total = UsageTotal()
    /// One entry per day and model (or account), for stacked charts.
    public var daysByModel: [Day] = []
    public var daysByAccount: [Day] = []
    public var byModel: [String: UsageTotal] = [:]
    public var byAccount: [String: UsageTotal] = [:]
    public var byConversation: [String: UsageTotal] = [:]
    public var lastUse: [String: Date] = [:]

    public init() {}

    /// Sums `buckets` that fall in `range`, attributing each to an account
    /// with `timeline` (nil account ids count under "").
    public static func make(_ buckets: [UsageBucket: Tokens], timeline: AccountTimeline, range: ClosedRange<Date>,
                            calendar: Calendar = .current) -> UsageReport {
        var report = UsageReport()
        var days: [Date: [String: UsageTotal]] = [:]
        var daysAccount: [Date: [String: UsageTotal]] = [:]
        for (bucket, tokens) in buckets {
            let date = Date(timeIntervalSince1970: Double(bucket.hour) * 3600)
            report.byConversation[bucket.conversation, default: UsageTotal()].add(tokens, bucket)
            report.lastUse[bucket.conversation] = max(report.lastUse[bucket.conversation] ?? .distantPast, date)
            guard range.contains(date) else { continue }
            let account = timeline.account(at: date, conversation: bucket.conversation) ?? ""
            let model = Pricing.displayName(bucket.model)
            let day = calendar.startOfDay(for: date)
            report.total.add(tokens, bucket)
            report.byModel[model, default: UsageTotal()].add(tokens, bucket)
            report.byAccount[account, default: UsageTotal()].add(tokens, bucket)
            days[day, default: [:]][model, default: UsageTotal()].add(tokens, bucket)
            daysAccount[day, default: [:]][account, default: UsageTotal()].add(tokens, bucket)
        }
        report.daysByModel = days.flatMap { day, models in models.map { Day(day: day, key: $0.key, total: $0.value) } }
            .sorted { ($0.day, $0.key) < ($1.day, $1.key) }
        report.daysByAccount = daysAccount.flatMap { day, accounts in accounts.map { Day(day: day, key: $0.key, total: $0.value) } }
            .sorted { ($0.day, $0.key) < ($1.day, $1.key) }
        return report
    }
}
