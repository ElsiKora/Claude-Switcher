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

    public init(profile: Profile) {
        id = profile.accountID
        org = profile.organizationID
        name = profile.name
        email = profile.email
        plan = profile.plan
    }

    public var displayName: String { name.isEmpty ? email : name }
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
    /// What claude.ai had billed beyond each plan by the end of each day:
    /// account id → "yyyy-MM-dd" → amount in minor units, as last read that day.
    public var extraByDay: [String: [String: Double]] = [:]
    /// When each account was being charged for extra usage.
    public var extraTracks: [String: ExtraTrack] = [:]

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
        extraByDay = try c.decodeIfPresent([String: [String: Double]].self, forKey: .extraByDay) ?? d.extraByDay
        extraTracks = try c.decodeIfPresent([String: ExtraTrack].self, forKey: .extraTracks) ?? d.extraTracks
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
        guard active else { return idleEvery }
        return (account.usage?.current(at: now).peak ?? 0) >= hotAt ? hotEvery : activeEvery
    }

    /// The account to switch to on its own, and why. `lastChat` is when
    /// anyone last worked in a chat, `commandRunning` whether a chat is
    /// running a shell command (which writes nothing until it ends).
    public static func autoTarget(_ st: SwitcherState, active: String?, claudeRunning: Bool, lastChat: Date?,
                                  commandRunning: Bool, now: Date) -> (Account, SwitchCause)? {
        guard claudeRunning, !st.holdChats, let cur = st.account(active), let usage = cur.usage,
              now.timeIntervalSince(usage.checkedAt) <= activeFresh,
              st.lastSwitch.map({ now.timeIntervalSince($0) >= cooldown }) ?? true
        else { return nil }

        if st.autoSwitch, usage.current(at: now).peak >= st.threshold,
           let best = st.accounts.filter({ usable($0, st, cur: cur, now: now) })
               .min(by: { $0.usage!.current(at: now).peak < $1.usage!.current(at: now).peak }) {
            return (best, .nearlyFull)
        }

        // The active account keeps going while its own week is the one running out.
        let handPaused = st.handSwitch.map { now.timeIntervalSince($0) < handPause } ?? false
        let chatting = commandRunning || (lastChat.map { now.timeIntervalSince($0) < idleFor } ?? false)
        if st.spendWeekly, !handPaused, !chatting, !spendable(cur, st, now: now),
           let best = st.accounts.filter({ usable($0, st, cur: cur, now: now) && spendable($0, st, now: now) })
               .min(by: { ($0.usage!.weeklyReset ?? .distantFuture) < ($1.usage!.weeklyReset ?? .distantFuture) }) {
            return (best, .spendWeekly)
        }
        return nil
    }

    /// The account with the most room left, when it has clearly more than the active one.
    public static func suggestion(_ st: SwitcherState, active: String?, now: Date) -> Account? {
        let curPeak = st.account(active)?.usage?.current(at: now).peak ?? 0
        let candidates = st.accounts.filter { a in
            a.id != active && a.problem == nil && a.usage.map { now.timeIntervalSince($0.checkedAt) <= idleFresh } == true
        }
        guard let best = candidates.min(by: { $0.usage!.current(at: now).peak < $1.usage!.current(at: now).peak }),
              best.usage!.current(at: now).peak <= curPeak - headroom
        else { return nil }
        return best
    }

    static func usable(_ a: Account, _ st: SwitcherState, cur: Account, now: Date) -> Bool {
        guard a.id != cur.id, a.problem == nil, let u = a.usage, now.timeIntervalSince(u.checkedAt) <= idleFresh else {
            return false
        }
        return u.current(at: now).peak < st.threshold - headroom
    }

    static func spendable(_ a: Account, _ st: SwitcherState, now: Date) -> Bool {
        if a.id == st.spending, let until = st.spendUntil, now < until { return true }
        guard let u = a.usage?.current(at: now), let reset = u.weeklyReset else { return false }
        let left = reset.timeIntervalSince(now)
        return left > 0 && left <= expiringWithin && u.weekly <= expiringMaxWeekly
    }
}
