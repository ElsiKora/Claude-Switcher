public import Foundation

/// A Claude account the switcher has seen signed in.
public struct Account: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var org: String
    public var name: String
    public var email: String
    public var plan: String
    public var usage: Usage?
    /// Why usage cannot be read, e.g. the saved sign-in has expired.
    public var problem: String?
    /// The workspaces of an account that has more than one with Claude
    /// (personal and Team); nil for an account with one. `org` and `usage`
    /// are the one Claude has open.
    public var orgs: [Org]?

    public init(profile: Profile) {
        id = profile.accountID
        org = profile.organizationID
        name = profile.name
        email = profile.email
        plan = profile.plan
    }

    public var displayName: String { name.isEmpty ? email : name }

    /// Whether the account has a plan Claude Code runs on (Pro, Max, Team,
    /// Enterprise). One without (the free plan) is shown, never rotated to.
    public var runsClaudeCode: Bool { !plan.isEmpty || (orgs?.count ?? 0) > 1 }
}

/// A workspace of an account on claude.ai, with limits of its own.
public struct Org: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case personal, team, enterprise
    }

    public var id: String
    public var name: String
    public var kind: Kind
    public var usage: Usage?
    public var problem: String?
    /// Shown and switchable by hand, but left out of automatic switching.
    public var excluded = false

    public init(id: String, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(Kind.self, forKey: .kind)
        usage = try c.decodeIfPresent(Usage.self, forKey: .usage)
        problem = try c.decodeIfPresent(String.self, forKey: .problem)
        excluded = try c.decodeIfPresent(Bool.self, forKey: .excluded) ?? false
    }
}

/// One set of limits Claude can be signed in to: an account in one of its
/// workspaces. What the switcher measures and switches between.
public struct Seat: Identifiable, Sendable, Equatable {
    public var account: Account
    public var orgID: String
    /// Set when the account has several workspaces: which one this is.
    public var org: Org?
    public var usage: Usage?
    public var problem: String?
    public var excluded: Bool

    /// Workspaces listed in `orgs` all have a Claude Code plan.
    public var runsClaudeCode: Bool { org != nil || account.runsClaudeCode }

    /// "<account>/<org>": limits belong to an account in a workspace.
    public var id: String { Self.key(account.id, orgID) }

    public static func key(_ account: String, _ org: String) -> String { "\(account)/\(org)" }

    /// The account as it is in this workspace: its limits there.
    public var inWorkspace: Account {
        var a = account
        a.org = orgID
        a.usage = usage
        a.problem = problem
        return a
    }

    /// "Alex · Team" for a workspace of a several-workspace account.
    public var displayName: String {
        guard let org else { return account.displayName }
        return "\(account.displayName) · \(org.label)"
    }
}

extension Org {
    /// "Personal" for one's own plan, the workspace's name for a team.
    public var label: String {
        kind == .personal ? String(localized: "Personal") : name
    }
}

extension SwitcherState {
    /// Every account in every workspace, in account order.
    public var seats: [Seat] {
        accounts.flatMap { a -> [Seat] in
            guard let orgs = a.orgs, orgs.count > 1 else {
                return [Seat(account: a, orgID: a.org, org: nil, usage: a.usage, problem: a.problem, excluded: false)]
            }
            return orgs.map { Seat(account: a, orgID: $0.id, org: $0, usage: $0.usage, problem: $0.problem ?? a.problem, excluded: $0.excluded) }
        }
    }

    public func seat(_ id: String?) -> Seat? {
        seats.first { $0.id == id }
    }

    /// The seat an account has open now.
    public func seat(of account: Account) -> Seat? {
        seat(Seat.key(account.id, account.org))
    }
}

public enum SwitchCause: String, Codable, Sendable {
    case byHand, nearlyFull, spendWeekly
}

/// What the switcher remembers between runs.
public struct SwitcherState: Codable, Sendable, Equatable {
    public var accounts: [Account] = []
    public var autoSwitch = false
    public var threshold: Double = Policy.defaultThreshold
    /// Moves to an account whose week is about to reset mostly unused.
    public var spendWeekly = false
    public var lastSwitch: Date?
    public var handSwitch: Date?
    public var lastCause: SwitchCause?
    public var lastFrom: String?
    /// Spend weekly moved to this account and keeps coming back to it until
    /// its week resets, even once more than half of it is used.
    public var spending: String?
    public var spendUntil: Date?
    /// Copies the per-account Claude Code settings along with each switch.
    public var mirrorSettings = true
    /// The account the others are set up like: its connectors, skills and plugins.
    public var reference: String?
    public var checkForUpdates = true
    /// A sound when a switch finishes.
    public var playSounds = true
    /// Notifications when a limit resets or nearly runs out.
    public var notify = true
    public var onboarded = false
    /// Which account was signed in when, for the analytics.
    public var timeline: AccountTimeline?
    public var updateChecked: Date?
    public var latestVersion: String?
    /// Adding several accounts: restarts keep cut-off chats waiting instead
    /// of continuing them, until this is turned off on the final account.
    public var holdChats = false
    /// Chats waiting to continue (chat ids without `local_`).
    public var heldChats: [String] = []
    /// When adding several accounts began or the last account was added;
    /// the mode ends on its own once this is `Policy.holdIdle` ago.
    public var holdSince: Date?
    /// What claude.ai had billed beyond each plan by the end of each day:
    /// account id → "yyyy-MM-dd" → amount in minor units, as last read that day.
    public var extraByDay: [String: [String: Double]] = [:]
    /// When each account was being charged for extra usage.
    public var extraTracks: [String: ExtraTrack] = [:]
    /// Each account's limits over the last hours, for the pace they are used at.
    public var history: [String: UsageHistory] = [:]
    /// Automatic switching is paused until then.
    public var pausedUntil: Date?
    /// Tell when one account's extra usage billed today passes this, in its own currency.
    public var extraAlert: Double?
    /// A notification each morning about the day before.
    public var morningSummary = true
    /// The day ("yyyy-MM-dd") the last morning summary was about.
    public var summaryDay: String?

    public init() {}

    public func account(_ id: String?) -> Account? {
        accounts.first { $0.id == id }
    }

    public mutating func update(_ id: String, _ change: (inout Account) -> Void) {
        if let i = accounts.firstIndex(where: { $0.id == id }) { change(&accounts[i]) }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SwitcherState()
        accounts = try c.decodeIfPresent([Account].self, forKey: .accounts) ?? d.accounts
        autoSwitch = try c.decodeIfPresent(Bool.self, forKey: .autoSwitch) ?? d.autoSwitch
        threshold = try c.decodeIfPresent(Double.self, forKey: .threshold) ?? d.threshold
        spendWeekly = try c.decodeIfPresent(Bool.self, forKey: .spendWeekly) ?? d.spendWeekly
        lastSwitch = try c.decodeIfPresent(Date.self, forKey: .lastSwitch)
        handSwitch = try c.decodeIfPresent(Date.self, forKey: .handSwitch)
        lastCause = try c.decodeIfPresent(SwitchCause.self, forKey: .lastCause)
        lastFrom = try c.decodeIfPresent(String.self, forKey: .lastFrom)
        spending = try c.decodeIfPresent(String.self, forKey: .spending)
        spendUntil = try c.decodeIfPresent(Date.self, forKey: .spendUntil)
        mirrorSettings = try c.decodeIfPresent(Bool.self, forKey: .mirrorSettings) ?? d.mirrorSettings
        reference = try c.decodeIfPresent(String.self, forKey: .reference)
        checkForUpdates = try c.decodeIfPresent(Bool.self, forKey: .checkForUpdates) ?? d.checkForUpdates
        playSounds = try c.decodeIfPresent(Bool.self, forKey: .playSounds) ?? d.playSounds
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? d.notify
        onboarded = try c.decodeIfPresent(Bool.self, forKey: .onboarded) ?? d.onboarded
        timeline = try c.decodeIfPresent(AccountTimeline.self, forKey: .timeline)
        updateChecked = try c.decodeIfPresent(Date.self, forKey: .updateChecked)
        latestVersion = try c.decodeIfPresent(String.self, forKey: .latestVersion)
        holdChats = try c.decodeIfPresent(Bool.self, forKey: .holdChats) ?? d.holdChats
        heldChats = try c.decodeIfPresent([String].self, forKey: .heldChats) ?? d.heldChats
        holdSince = try c.decodeIfPresent(Date.self, forKey: .holdSince) ?? (holdChats ? .now : nil)
        extraByDay = try c.decodeIfPresent([String: [String: Double]].self, forKey: .extraByDay) ?? d.extraByDay
        extraTracks = try c.decodeIfPresent([String: ExtraTrack].self, forKey: .extraTracks) ?? d.extraTracks
        history = try c.decodeIfPresent([String: UsageHistory].self, forKey: .history) ?? d.history
        pausedUntil = try c.decodeIfPresent(Date.self, forKey: .pausedUntil)
        extraAlert = try c.decodeIfPresent(Double.self, forKey: .extraAlert)
        morningSummary = try c.decodeIfPresent(Bool.self, forKey: .morningSummary) ?? d.morningSummary
        summaryDay = try c.decodeIfPresent(String.self, forKey: .summaryDay)
    }
}

/// When the switcher moves Claude to another account on its own, and which
/// account is the best pick by hand.
public enum Policy {
    public static let defaultThreshold: Double = 96
    public static let thresholds: [Double] = [90, 94, 96, 98]
    /// An automatic switch only goes to an account this far below the threshold.
    static let headroom: Double = 10
    /// No second automatic switch this soon after the last switch.
    static let cooldown: TimeInterval = 10 * 60
    /// Spend weekly: a week that resets this soon with at most this much used
    /// is worth moving to before the rest is lost.
    static let expiringWithin: TimeInterval = 24 * 3600
    static let expiringMaxWeekly: Double = 50
    /// A switch by hand pauses spend weekly this long.
    static let handPause: TimeInterval = 5 * 3600
    /// Spend weekly is never urgent, so it waits for chats to be idle this long.
    static let idleFor: TimeInterval = 15 * 60
    /// Adding several accounts ends on its own this long after the last
    /// account was added, once chats are idle.
    public static let holdIdle: TimeInterval = 30 * 60

    // Polling. The usage endpoint is rate-limited per account and Claude polls it too.
    public static let activeEvery: TimeInterval = 2 * 60
    public static let hotEvery: TimeInterval = 60
    public static let hotAt: Double = 85
    public static let idleEvery: TimeInterval = 10 * 60
    static let activeFresh: TimeInterval = 5 * 60
    static let idleFresh: TimeInterval = idleEvery + 5 * 60
    public static let maxBackoff: TimeInterval = 30 * 60

    /// How often an account's usage is read.
    public static func interval(for account: Account, active: Bool, now: Date) -> TimeInterval {
        interval(usage: account.usage, active: active, now: now)
    }

    /// How often limits are read: often for the one in use, more often near full.
    public static func interval(usage: Usage?, active: Bool, now: Date) -> TimeInterval {
        guard active else { return idleEvery }
        return (usage?.current(at: now).peak ?? 0) >= hotAt ? hotEvery : activeEvery
    }

    /// What the switcher knows besides the state when it decides.
    public struct Context: Sendable {
        public var claudeRunning: Bool
        /// When anyone last worked in a chat.
        public var lastChat: Date?
        /// Whether a chat is running a shell command.
        public var commandRunning: Bool
        /// What re-reading every open chat would cost in the new account, at
        /// API prices, and what a percent of a weekly limit is worth there.
        public var switchCost: Double?
        public var dollarsPerWeeklyPercent: Double?
        public var now: Date

        public init(claudeRunning: Bool, lastChat: Date? = nil, commandRunning: Bool = false,
                    switchCost: Double? = nil, dollarsPerWeeklyPercent: Double? = nil, now: Date) {
            self.claudeRunning = claudeRunning
            self.lastChat = lastChat
            self.commandRunning = commandRunning
            self.switchCost = switchCost
            self.dollarsPerWeeklyPercent = dollarsPerWeeklyPercent
            self.now = now
        }
    }

    /// How soon a switch has to happen.
    public enum Urgency: Sendable, Equatable {
        /// The limit runs out within minutes: switch now, even mid-reply.
        case now
        /// It runs out soon: switch at the next pause between replies, at most `pauseWait` from now.
        case soon
    }

    /// How far ahead the pace is projected: a little past the next check.
    static let horizon: TimeInterval = 3 * 60
    /// With extra usage on, running out costs money, so the switch comes earlier.
    static let paidHorizon: TimeInterval = 6 * 60
    /// The longest a "soon" switch waits for a pause between replies.
    public static let pauseWait: TimeInterval = 3 * 60
    /// A pause: no chat wrote for this long.
    public static let pause: TimeInterval = 45
    /// A move to an expiring week has to be worth this many times what it costs.
    static let worthIt: Double = 3

    /// The account to switch to on its own, why, and how soon.
    public static func autoTarget(_ st: SwitcherState, active: String?, context c: Context) -> (Seat, SwitchCause, Urgency)? {
        let now = c.now
        // Adding several accounts holds chats, but running out still moves on:
        // the switch ends the mode and continues the held chats there.
        guard c.claudeRunning, st.pausedUntil.map({ now >= $0 }) ?? true,
              let cur = st.seat(active), let usage = cur.usage,
              now.timeIntervalSince(usage.checkedAt) <= activeFresh,
              st.lastSwitch.map({ now.timeIntervalSince($0) >= cooldown }) ?? true
        else { return nil }
        let u = usage.current(at: now)
        let forecast = Forecast(usage: usage, history: st.history[cur.id], now: now)

        if st.autoSwitch {
            // Runs out at this pace before long, or has reached the threshold.
            let paid = usage.extra?.enabled == true
            let ahead = forecast.peak(of: usage, in: paid ? paidHorizon : horizon, now: now)
            if u.peak >= st.threshold || ahead >= 99, let best = best(st, cur: cur, now: now) {
                let soonFull = forecast.peak(of: usage, in: 90, now: now) >= 99.5
                return (best, .nearlyFull, u.peak >= 99 || soonFull ? .now : .soon)
            }
        }

        // The active account keeps going while its own week is the one running out.
        let handPaused = st.handSwitch.map { now.timeIntervalSince($0) < handPause } ?? false
        let chatting = c.commandRunning || (c.lastChat.map { now.timeIntervalSince($0) < idleFor } ?? false)
        if st.spendWeekly, !st.holdChats, !handPaused, !chatting, !spendable(cur, st, now: now),
           let best = st.seats.filter({ usable($0, st, cur: cur, now: now) && spendable($0, st, now: now) })
               .min(by: { ($0.usage!.weeklyReset ?? .distantFuture) < ($1.usage!.weeklyReset ?? .distantFuture) }),
           worth(best, st, c) {
            return (best, .spendWeekly, .soon)
        }
        return nil
    }

    /// Whether adding several accounts should end on its own: no account
    /// was added for `holdIdle` and no chat is at work.
    public static func finishAdding(_ st: SwitcherState, context c: Context) -> Bool {
        guard st.holdChats, c.claudeRunning, let since = st.holdSince else { return false }
        let chatting = c.commandRunning || (c.lastChat.map { c.now.timeIntervalSince($0) < idleFor } ?? false)
        return c.now.timeIntervalSince(since) >= holdIdle && !chatting
    }

    /// The active account has reached the threshold and no account has room
    /// to move to. `next` is the account that has room again first, and when.
    public struct NoRoom: Sendable, Equatable {
        public var seat: Seat
        public var next: (seat: Seat, at: Date)?

        public static func == (a: NoRoom, b: NoRoom) -> Bool {
            a.seat.id == b.seat.id && a.next?.seat.id == b.next?.seat.id && a.next?.at == b.next?.at
        }
    }

    public static func noRoom(_ st: SwitcherState, active: String?, now: Date) -> NoRoom? {
        guard let cur = st.seat(active), let usage = cur.usage, usage.current(at: now).peak >= st.threshold,
              best(st, cur: cur, now: now) == nil else { return nil }
        let line = st.threshold - headroom
        // When each other account, and this one, is below the line again.
        let frees = st.seats.compactMap { seat -> (seat: Seat, at: Date)? in
            guard seat.problem == nil, !seat.excluded, seat.runsClaudeCode, let u = seat.usage else { return nil }
            let windows = [(u.session, u.sessionReset), (u.weekly, u.weeklyReset)].filter { $0.0 >= line }
            guard !windows.isEmpty else { return nil }
            let resets = windows.compactMap(\.1)
            guard resets.count == windows.count, let at = resets.max(), at > now else { return nil }
            return (seat, at)
        }
        return NoRoom(seat: cur, next: frees.min { $0.at < $1.at })
    }

    /// The account to move to when the active one runs out: the one whose
    /// free room would be lost first (a 5-hour window or a week about to
    /// reset), else the one with the most room. Room that would be lost is
    /// worth using before room that keeps.
    static func best(_ st: SwitcherState, cur: Seat, now: Date) -> Seat? {
        let candidates = st.seats.filter { usable($0, st, cur: cur, now: now) }
        func expires(_ a: Seat) -> Date? {
            let u = a.usage!.current(at: now)
            let windows: [(Double, Date?)] = [(100 - u.session, u.sessionReset), (100 - u.weekly, u.weeklyReset)]
            return windows.compactMap { room, reset in room >= minRoom ? reset : nil }.min()
        }
        return candidates.min { a, b in
            switch (expires(a), expires(b)) {
            case let (x?, y?) where x != y: x < y
            case (_?, nil): true
            case (nil, _?): false
            default: a.usage!.current(at: now).peak < b.usage!.current(at: now).peak
            }
        }
    }

    /// Room a window needs to count as worth using before it resets.
    static let minRoom: Double = 20

    /// Whether moving to `target` for its expiring week gains clearly more
    /// than the switch costs: the week it has left against re-reading every
    /// open chat. Without the figures to tell, it moves, as it always has.
    static func worth(_ target: Seat, _ st: SwitcherState, _ c: Context) -> Bool {
        guard let cost = c.switchCost, let perPercent = c.dollarsPerWeeklyPercent, perPercent > 0,
              let u = target.usage?.current(at: c.now) else { return true }
        let gain = (100 - u.weekly) * perPercent
        return gain >= worthIt * cost
    }

    /// The account with the most room left, when it has clearly more than the active one.
    public static func suggestion(_ st: SwitcherState, active: String?, now: Date) -> Seat? {
        let curPeak = st.seat(active)?.usage?.current(at: now).peak ?? 0
        let candidates = st.seats.filter { a in
            a.id != active && a.problem == nil && !a.excluded && a.runsClaudeCode
                && a.usage.map { now.timeIntervalSince($0.checkedAt) <= idleFresh } == true
        }
        guard let best = candidates.min(by: { $0.usage!.current(at: now).peak < $1.usage!.current(at: now).peak }),
              best.usage!.current(at: now).peak <= curPeak - headroom
        else { return nil }
        return best
    }

    static func usable(_ a: Seat, _ st: SwitcherState, cur: Seat, now: Date) -> Bool {
        guard a.id != cur.id, a.problem == nil, !a.excluded, a.runsClaudeCode, let u = a.usage,
              now.timeIntervalSince(u.checkedAt) <= idleFresh else {
            return false
        }
        // Below the threshold with room to spare, so never one that is
        // already at its limit and billing extra usage.
        return u.current(at: now).peak < st.threshold - headroom
    }

    static func spendable(_ a: Seat, _ st: SwitcherState, now: Date) -> Bool {
        if a.id == st.spending, let until = st.spendUntil, now < until { return true }
        guard let u = a.usage?.current(at: now), let reset = u.weeklyReset else { return false }
        let left = reset.timeIntervalSince(now)
        return left > 0 && left <= expiringWithin && u.weekly <= expiringMaxWeekly
    }
}
