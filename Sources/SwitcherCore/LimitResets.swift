public import Foundation

/// Limit resets an account can use by hand: the reset grants claude.ai
/// reports in its usage answer (`cedar_ember`). Each grant refills some of
/// the account's limits, a set number of times, until its use-by date. A
/// reset is used in Claude itself, once the account reaches a limit the
/// grant refills. Claude Switcher shows them and never uses one.
public struct LimitResets: Codable, Sendable, Equatable {
    public struct Grant: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        /// claude.ai's own name for the grant, when it has one.
        public var label: String?
        public var left: Int
        public var total: Int
        /// Resets still left then are lost.
        public var endsAt: Date
        /// The limits one reset refills: `five_hour`, `seven_day`, `seven_day_opus`, …
        public var refills: [String]
        /// A Fable reset: what Fable used goes back into the weekly limit.
        public var givesBackWeekly: Bool
        public var paused: Bool
        /// The one Claude would use now: the account is at a limit it refills.
        public var usableNow: Bool

        public init(id: String, label: String? = nil, left: Int, total: Int, endsAt: Date, refills: [String],
                    givesBackWeekly: Bool = false, paused: Bool = false, usableNow: Bool = false) {
            self.id = id
            self.label = label
            self.left = left
            self.total = total
            self.endsAt = endsAt
            self.refills = refills
            self.givesBackWeekly = givesBackWeekly
            self.paused = paused
            self.usableNow = usableNow
        }

        public var refillsFiveHour: Bool { refills.contains("five_hour") }
        /// The week as a whole or a model's week.
        public var refillsWeekly: Bool { givesBackWeekly || refills.contains { $0.hasPrefix("seven_day") } }

        /// Not paused, not past its date, and a reset left.
        public func isActive(at now: Date) -> Bool { !paused && endsAt > now && left > 0 }
    }

    /// Whether the account takes part; when it does not, `ineligibleReason`
    /// says why (`not_enrolled`, `tier`, `no_grant`, …).
    public var eligible: Bool
    public var ineligibleReason: String?
    /// The limits the account was at when it was read.
    public var atLimit: [String]
    /// No reset can be used before this.
    public var cooldownUntil: Date?
    public var grants: [Grant]

    public init(eligible: Bool, ineligibleReason: String? = nil, atLimit: [String] = [], cooldownUntil: Date? = nil,
                grants: [Grant] = []) {
        self.eligible = eligible
        self.ineligibleReason = ineligibleReason
        self.atLimit = atLimit
        self.cooldownUntil = cooldownUntil
        self.grants = grants
    }

    /// The grants that can still be used, the one ending first first.
    public func active(at now: Date) -> [Grant] {
        grants.filter { $0.isActive(at: now) }.sorted { $0.endsAt < $1.endsAt }
    }

    /// How many resets are left in all.
    public func left(at now: Date) -> Int {
        active(at: now).reduce(0) { $0 + $1.left }
    }
}

extension LimitResets {
    /// Reads `cedar_ember` the way claude.ai's own client does: nil when it
    /// is missing or says nothing about eligibility, and a grant without an
    /// id, a count or a use-by date is left out.
    public init?(json: Any?) {
        guard let o = json as? [String: Any], let eligible = o["eligible"] as? Bool else { return nil }
        let atLimit = o["at_limit"] as? Bool == true ? (o["exhausted"] as? [String] ?? []) : []
        let cooldown = AnthropicAPI.date(o["cooldown_until"] as? String)
        // Claude uses the grant it names next, and none during a cooldown.
        let next = cooldown == nil ? o["next_grant_id"] as? String : nil
        var grants: [Grant] = []
        for case let g as [String: Any] in (eligible ? o["grants"] as? [Any] : nil) ?? [] {
            guard let id = g["id"] as? String, !id.isEmpty, !grants.contains(where: { $0.id == id }),
                  let total = (g["resets_total"] as? NSNumber)?.intValue, total >= 1,
                  let left = (g["resets_left"] as? NSNumber)?.intValue, left >= 0,
                  let endsAt = AnthropicAPI.date(g["ends_at"] as? String) else { continue }
            let refills = g["clears"] as? [String] ?? []
            let givesBack = g["gives_back_weekly"] as? Bool == true
            let paused = g["paused"] as? Bool == true
            let blocked = (g["blocking"] as? [String] ?? []).contains { !refills.contains($0) }
            // A Fable reset gives back to the weekly limit even when its list leaves it out.
            let refilled = givesBack && !refills.contains("seven_day") ? refills + ["seven_day"] : refills
            let needsLimit = g["use_requires_limit"] as? Bool != false
            let usable = g["usable_now"] as? Bool == true && !paused && !blocked && id == next
                && (!needsLimit || refilled.contains { atLimit.contains($0) })
                && !grants.contains(where: \.usableNow)
            grants.append(Grant(id: id, label: (g["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }, left: min(left, total),
                                total: total, endsAt: endsAt, refills: refills, givesBackWeekly: givesBack, paused: paused,
                                usableNow: usable))
        }
        self.init(eligible: eligible, ineligibleReason: eligible ? nil : o["ineligible_reason"] as? String, atLimit: atLimit,
                  cooldownUntil: cooldown, grants: grants)
    }
}
