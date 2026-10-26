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

    public mutating func merge(_ other: UsageTotal) {
        tokens = tokens + other.tokens
        cost += other.cost
        unpriced += other.unpriced
    }

    /// Share of input served from the cache.
    public var cacheHitRate: Double {
        let all = tokens.input + tokens.cacheRead + tokens.write5m + tokens.write1h
        return all == 0 ? 0 : Double(tokens.cacheRead) / Double(all)
    }
}

/// Which accounts and models the analytics count; nil counts all.
public struct UsageFilter: Sendable, Equatable {
    /// Account ids; "" is usage no account can be named for.
    public var accounts: Set<String>?
    /// Model names as `Pricing.displayName` gives them.
    public var models: Set<String>?

    public init(accounts: Set<String>? = nil, models: Set<String>? = nil) {
        self.accounts = accounts
        self.models = models
    }

    public static let all = UsageFilter()

    func includes(account: String, model: String) -> Bool {
        (accounts?.contains(account) ?? true) && (models?.contains(model) ?? true)
    }
}

/// Usage broken down for the analytics page.
public struct UsageReport: Sendable {
    /// One day of one model in one account: the finest grain the page sorts and groups.
    public struct Cell: Sendable {
        public var day: Date
        public var account: String
        public var model: String
        public var total: UsageTotal
    }

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
    /// All time, whatever the range and filter, for the chat list.
    public var byConversation: [String: UsageTotal] = [:]
    /// In the range and filter.
    public var byConversationInRange: [String: UsageTotal] = [:]
    public var cells: [Cell] = []
    /// Accounts and models with usage in the range, before the filter.
    public var accountsSeen: Set<String> = []
    public var modelsSeen: Set<String> = []
    public var lastUse: [String: Date] = [:]

    public init() {}

    /// Sums `buckets` that fall in `range`, attributing each to an account
    /// with `timeline` (nil account ids count under "").
    public static func make(_ buckets: [UsageBucket: Tokens], timeline: AccountTimeline, range: ClosedRange<Date>,
                            filter: UsageFilter = .all, calendar: Calendar = .current) -> UsageReport {
        var report = UsageReport()
        var days: [Date: [String: UsageTotal]] = [:]
        var daysAccount: [Date: [String: UsageTotal]] = [:]
        struct CellKey: Hashable { var day: Date; var account: String; var model: String }
        var cells: [CellKey: UsageTotal] = [:]
        for (bucket, tokens) in buckets {
            let date = Date(timeIntervalSince1970: Double(bucket.hour) * 3600)
            report.byConversation[bucket.conversation, default: UsageTotal()].add(tokens, bucket)
            report.lastUse[bucket.conversation] = max(report.lastUse[bucket.conversation] ?? .distantPast, date)
            guard range.contains(date) else { continue }
            let account = timeline.account(at: date, conversation: bucket.conversation) ?? ""
            let model = Pricing.displayName(bucket.model)
            let day = calendar.startOfDay(for: date)
            report.accountsSeen.insert(account)
            report.modelsSeen.insert(model)
            guard filter.includes(account: account, model: model) else { continue }
            cells[CellKey(day: day, account: account, model: model), default: UsageTotal()].add(tokens, bucket)
            report.byConversationInRange[bucket.conversation, default: UsageTotal()].add(tokens, bucket)
            report.total.add(tokens, bucket)
            report.byModel[model, default: UsageTotal()].add(tokens, bucket)
            report.byAccount[account, default: UsageTotal()].add(tokens, bucket)
            days[day, default: [:]][model, default: UsageTotal()].add(tokens, bucket)
            daysAccount[day, default: [:]][account, default: UsageTotal()].add(tokens, bucket)
        }
        report.daysByModel = days.flatMap { day, models in models.map { Day(day: day, key: $0.key, total: $0.value) } }
            .sorted { ($0.day, $0.key) < ($1.day, $1.key) }
        report.cells = cells.map { Cell(day: $0.key.day, account: $0.key.account, model: $0.key.model, total: $0.value) }
        report.daysByAccount = daysAccount.flatMap { day, accounts in accounts.map { Day(day: day, key: $0.key, total: $0.value) } }
            .sorted { ($0.day, $0.key) < ($1.day, $1.key) }
        return report
    }
}

/// What claude.ai billed beyond each plan, per day, from the month-to-date
/// amounts the switcher reads with each usage check. claude.ai only reports
/// the month so far, so a day is the difference to the day before; the first
/// day recorded has nothing to compare with and counts as unknown.
public enum ExtraLedger {
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func day(_ key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Day → amount billed that day, in minor units. A new month starts from zero.
    public static func daily(_ monthToDate: [String: Double], calendar: Calendar = .current) -> [Date: Double] {
        let days = monthToDate.keys.sorted()
        var out: [Date: Double] = [:]
        for (i, key) in days.enumerated() where i > 0 {
            guard let date = day(key, calendar: calendar), let value = monthToDate[key],
                  let previous = monthToDate[days[i - 1]], let previousDate = day(days[i - 1], calendar: calendar) else { continue }
            let sameMonth = calendar.isDate(date, equalTo: previousDate, toGranularity: .month)
            out[date] = sameMonth ? max(0, value - previous) : value
        }
        return out
    }

    /// Since when there are daily amounts: the day after the first one recorded.
    public static func since(_ monthToDate: [String: Double], calendar: Calendar = .current) -> Date? {
        monthToDate.keys.sorted().dropFirst().first.flatMap { day($0, calendar: calendar) }
    }
}
