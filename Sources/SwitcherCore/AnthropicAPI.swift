public import Foundation

/// Spend beyond the plan's limits, billed at API prices (in cents, as claude.ai reports it).
public struct ExtraUsage: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var usedCents: Double?
    public var limitCents: Double?
    public var currency: String?

    public init(enabled: Bool, usedCents: Double?, limitCents: Double?, currency: String?) {
        self.enabled = enabled
        self.usedCents = usedCents
        self.limitCents = limitCents
        self.currency = currency
    }

    public var used: Double? { usedCents.map { $0 / 100 } }
    public var limit: Double? { limitCents.map { $0 / 100 } }
}

/// An account's plan usage in percent, as Claude shows it.
public struct Usage: Codable, Sendable, Equatable {
    public var session: Double
    public var sessionReset: Date?
    public var weekly: Double
    public var weeklyReset: Date?
    public var checkedAt: Date
    /// Extra usage billed beyond the plan this month, when the plan has it on.
    public var extra: ExtraUsage?

    public init(session: Double, sessionReset: Date?, weekly: Double, weeklyReset: Date?, checkedAt: Date) {
        self.session = session
        self.sessionReset = sessionReset
        self.weekly = weekly
        self.weeklyReset = weeklyReset
        self.checkedAt = checkedAt
    }

    /// The fuller of the two limits.
    public var peak: Double { max(session, weekly) }

    /// Usage with windows that have reset since the last check set to zero.
    public func current(at now: Date) -> Usage {
        var c = self
        if let r = sessionReset, now > r { c.session = 0; c.sessionReset = nil }
        if let r = weeklyReset, now > r { c.weekly = 0; c.weeklyReset = nil }
        return c
    }
}

public struct Profile: Sendable, Equatable {
    public var accountID: String
    public var organizationID: String
    public var name: String
    public var email: String
    public var plan: String

    public init(accountID: String, organizationID: String, name: String, email: String, plan: String) {
        self.accountID = accountID
        self.organizationID = organizationID
        self.name = name
        self.email = email
        self.plan = plan
    }
}

public enum APIError: LocalizedError, Equatable {
    case signedOut
    case rateLimited(retryAfter: TimeInterval?)
    case status(Int)

    public var errorDescription: String? {
        switch self {
        case .signedOut: String(localized: "The sign-in has expired. Add the account again.")
        case .rateLimited: String(localized: "Anthropic asked to wait before checking usage again.")
        case let .status(code): String(localized: "api.anthropic.com answered \(code).")
        }
    }
}

/// The profile and usage endpoints Claude and Claude Code use themselves.
/// Tokens are sent to api.anthropic.com and nowhere else.
public struct AnthropicAPI: Sendable {
    public static let base = URL(string: "https://api.anthropic.com")!

    let session: URLSession
    let userAgent: String

    public init(userAgent: String, session: URLSession = .shared) {
        self.userAgent = userAgent
        self.session = session
    }

    public func profile(token: String) async throws -> Profile {
        struct Body: Decodable {
            struct Account: Decodable {
                var uuid: String
                var display_name: String?
                var full_name: String?
                var email: String?
                var has_claude_max: Bool?
                var has_claude_pro: Bool?
            }
            struct Organization: Decodable {
                var uuid: String
                var organization_type: String?
            }
            var account: Account
            var organization: Organization
        }
        let body: Body = try await get("/api/oauth/profile", token: token)
        let type = (body.organization.organization_type ?? "").replacing("claude_", with: "", maxReplacements: 1)
        let plan: String = switch type {
        case "max", "pro", "team", "enterprise": type.prefix(1).uppercased() + type.dropFirst()
        default: body.account.has_claude_max == true ? "Max" : body.account.has_claude_pro == true ? "Pro" : ""
        }
        return Profile(
            accountID: body.account.uuid,
            organizationID: body.organization.uuid,
            name: body.account.display_name ?? body.account.full_name ?? "",
            email: body.account.email ?? "",
            plan: plan)
    }

    public func usage(token: String) async throws -> Usage {
        struct Window: Decodable {
            var utilization: Double?
            var resets_at: String?
        }
        struct Extra: Decodable {
            var is_enabled: Bool?
            var monthly_limit: Double?
            var used_credits: Double?
            var currency: String?
        }
        struct Body: Decodable {
            var five_hour: Window?
            var seven_day: Window?
            var extra_usage: Extra?
        }
        let body: Body = try await get("/api/oauth/usage", token: token)
        var usage = Usage(
            session: body.five_hour?.utilization ?? 0,
            sessionReset: Self.date(body.five_hour?.resets_at),
            weekly: body.seven_day?.utilization ?? 0,
            weeklyReset: Self.date(body.seven_day?.resets_at),
            checkedAt: .now)
        if let e = body.extra_usage {
            usage.extra = ExtraUsage(enabled: e.is_enabled ?? false, usedCents: e.used_credits, limitCents: e.monthly_limit, currency: e.currency)
        }
        return usage
    }

    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s))
            ?? (try? Date.ISO8601FormatStyle().parse(s))
    }

    private func get<T: Decodable>(_ path: String, token: String) async throws -> T {
        var request = URLRequest(url: Self.base.appending(path: path))
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        switch http?.statusCode ?? 0 {
        case 200:
            return try JSONDecoder().decode(T.self, from: data)
        case 401:
            throw APIError.signedOut
        case 429:
            throw APIError.rateLimited(retryAfter: http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        case let code:
            throw APIError.status(code)
        }
    }
}

/// The decrypted `oauth:tokenCacheV2` of a sign-in.
public enum TokenCache {
    /// An unexpired access token of `account` that may read its profile and
    /// usage. Cache keys look like `acct:<account>|<client>:<org>:<audience>:<scopes>`.
    public static func accessToken(fromEncrypted value: String, account: String, storage: SafeStorage = .shared, now: Date = .now) throws -> String {
        guard let data = Data(base64Encoded: value) else { throw SafeStorageError.unexpectedFormat }
        return try accessToken(fromPlain: storage.decrypt(data), account: account, now: now)
    }

    static func accessToken(fromPlain plain: Data, account: String, now: Date) throws -> String {
        struct Entry: Decodable {
            var token: String
            var expiresAt: Int64
        }
        let cache = try JSONDecoder().decode([String: Entry].self, from: plain)
        let nowMS = Int64(now.timeIntervalSince1970 * 1000)
        let best = cache
            .filter { $0.key.hasPrefix("acct:\(account)|") && $0.key.contains("user:profile") && $0.value.expiresAt > nowMS }
            .max { $0.value.expiresAt < $1.value.expiresAt }
        guard let best else { throw APIError.signedOut }
        return best.value.token
    }
}
