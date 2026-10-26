public import Foundation
import CryptoKit
import SQLite3

/// Talks to claude.ai with an account's own web session, the way claude.ai's
/// Settings page does, for what lives only on claude.ai: connectors and the
/// permissions of their tools. The session is the `sessionKey` cookie Claude
/// keeps in its cookie store, encrypted with "Claude Safe Storage" like the
/// sign-in; it is sent to claude.ai and nowhere else.
public struct ClaudeWeb: Sendable {
    public static let base = URL(string: "https://claude.ai")!

    let cookieHeader: String
    let session: URLSession
    let userAgent: String

    /// Reads the claude.ai cookies of a cookie store (Claude's live one, or a
    /// saved sign-in's copy). The file is copied first: Claude may hold it open.
    public init(cookieStore: URL, storage: SafeStorage = .shared, userAgent: String, session: URLSession = .shared) throws {
        cookieHeader = try Self.cookies(in: cookieStore, storage: storage)
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
        self.userAgent = userAgent
        self.session = session
    }

    // MARK: - Requests

    public func get(_ path: String) async throws -> (status: Int, body: Data) {
        try await send("GET", path, body: nil)
    }

    /// A GET that must answer a JSON array.
    public func list(_ path: String) async throws -> [[String: Any]] {
        let (status, data) = try await get(path)
        guard status == 200, let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw Self.failure(status, data)
        }
        return list
    }

    /// A GET that must answer a JSON object.
    public func object(_ path: String) async throws -> [String: Any] {
        let (status, data) = try await get(path)
        guard status == 200, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Self.failure(status, data)
        }
        return object
    }

    public func send(_ method: String, _ path: String, json: [String: Any]) async throws -> (status: Int, body: Data) {
        try await send(method, path, body: JSONSerialization.data(withJSONObject: json))
    }

    static func failure(_ status: Int, _ data: Data) -> APIError {
        status == 401 || status == 403 ? .signedOut : .status(status)
    }

    public func send(_ method: String, _ path: String, body: Data?) async throws -> (status: Int, body: Data) {
        guard let url = URL(string: path, relativeTo: Self.base) else { throw APIError.status(0) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.httpShouldHandleCookies = false
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    // MARK: - Cookies

    struct Cookie {
        var name: String
        var value: String
        var host = "claude.ai"
        var path = "/"
        var secure = true
        var httpOnly = false
        /// Microseconds since 1601-01-01, Chromium's clock; 0 for a session cookie.
        var expires: Int64 = 0
    }

    // MARK: - Workspaces

    /// The account's workspaces with Claude (chat), from claude.ai: its own
    /// plan and the teams it belongs to. API-only organizations are left out.
    public func orgs() async throws -> [Org] {
        try await list("/api/organizations").compactMap { o in
            guard let id = o["uuid"] as? String, (o["capabilities"] as? [String])?.contains("chat") == true else { return nil }
            let raven = o["raven_type"] as? String
            let kind: Org.Kind = raven == "enterprise" ? .enterprise : raven == nil ? .personal : .team
            return Org(id: id, name: o["name"] as? String ?? "", kind: kind)
        }
    }

    /// A workspace's limits, as claude.ai's usage page reads them.
    public func usage(org: String) async throws -> Usage {
        let body = try await object("/api/organizations/\(org)/usage")
        func window(_ key: String) -> (Double?, String?) {
            let w = body[key] as? [String: Any]
            return ((w?["utilization"] as? NSNumber)?.doubleValue, w?["resets_at"] as? String)
        }
        let (session, sessionReset) = window("five_hour")
        let (weekly, weeklyReset) = window("seven_day")
        let e = body["extra_usage"] as? [String: Any]
        return AnthropicAPI.usage(session, sessionReset, weekly, weeklyReset, extra: e.map {
            (($0["is_enabled"] as? NSNumber)?.boolValue, ($0["used_credits"] as? NSNumber)?.doubleValue,
             ($0["monthly_limit"] as? NSNumber)?.doubleValue, $0["currency"] as? String)
        })
    }

    /// Sets the workspace claude.ai and Claude open: the `lastActiveOrg`
    /// cookie, which Claude reads when it starts and mints its sign-in for.
    /// Claude must be closed. The cookie has to exist: Claude writes it the
    /// first time the account opens a workspace.
    public static func setActiveOrg(_ org: String, in store: URL, storage: SafeStorage = .shared) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { throw SafeStorageError.unexpectedFormat }
        defer { sqlite3_close(db) }
        var version = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = 'version'", -1, &stmt, nil) == SQLITE_OK,
           sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) {
            version = Int(String(cString: text)) ?? 0
        }
        sqlite3_finalize(stmt)
        let sql = "SELECT host_key FROM cookies WHERE name = 'lastActiveOrg' AND (host_key = '.claude.ai' OR host_key = 'claude.ai')"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW,
              let hostText = sqlite3_column_text(stmt, 0) else {
            sqlite3_finalize(stmt)
            throw ClaudeWebError.noActiveOrgCookie
        }
        let host = String(cString: hostText)
        sqlite3_finalize(stmt)
        // From version 24 on, the plaintext starts with a SHA-256 of the cookie's host.
        var plain = Data(org.utf8)
        if version >= 24 { plain = Data(SHA256.hash(data: Data(host.utf8))) + plain }
        let encrypted = try storage.encrypt(plain)
        let update = "UPDATE cookies SET encrypted_value = ?, value = '' WHERE name = 'lastActiveOrg' AND host_key = ?"
        guard sqlite3_prepare_v2(db, update, -1, &stmt, nil) == SQLITE_OK else { throw SafeStorageError.unexpectedFormat }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = encrypted.withUnsafeBytes { sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32($0.count), transient) }
        sqlite3_bind_text(stmt, 2, host, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SafeStorageError.unexpectedFormat }
    }

    /// One claude.ai cookie's value, decrypted.
    public static func cookie(_ name: String, in store: URL, storage: SafeStorage = .shared) throws -> String? {
        try cookies(in: store, storage: storage).first { $0.name == name }?.value
    }

    /// The claude.ai cookies of a cookie store as `HTTPCookie`s, for a web
    /// view that opens claude.ai as that account. They are scoped to
    /// claude.ai, so pages of other sites never see them.
    public static func webCookies(cookieStore: URL, storage: SafeStorage = .shared) throws -> [HTTPCookie] {
        try cookies(in: cookieStore, storage: storage).compactMap { c in
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: c.name, .value: c.value, .domain: c.host, .path: c.path,
            ]
            if c.secure { properties[.secure] = "TRUE" }
            if c.httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if c.expires > 0 {
                properties[.expires] = Date(timeIntervalSince1970: Double(c.expires) / 1_000_000 - 11_644_473_600)
            }
            return HTTPCookie(properties: properties)
        }
    }

    /// The claude.ai cookies, decrypted. Chromium prefixes each value with a
    /// SHA-256 of its host from cookie database version 24 on.
    static func cookies(in store: URL, storage: SafeStorage) throws -> [Cookie] {
        let copy = FileManager.default.temporaryDirectory.appending(path: "claude-switcher-cookies-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: store, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw SafeStorageError.unexpectedFormat }
        defer { sqlite3_close(db) }

        var version = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = 'version'", -1, &stmt, nil) == SQLITE_OK,
           sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) {
            version = Int(String(cString: text)) ?? 0
        }
        sqlite3_finalize(stmt)

        let sql = """
            SELECT name, value, encrypted_value, host_key, path, is_secure, is_httponly, expires_utc
            FROM cookies WHERE host_key = 'claude.ai' OR host_key = '.claude.ai'
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw SafeStorageError.unexpectedFormat }
        defer { sqlite3_finalize(stmt) }
        var out: [Cookie] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 0))
            var value = String(cString: sqlite3_column_text(stmt, 1))
            let count = Int(sqlite3_column_bytes(stmt, 2))
            if value.isEmpty, count > 0, let bytes = sqlite3_column_blob(stmt, 2) {
                var plain = try storage.decrypt(Data(bytes: bytes, count: count))
                if version >= 24, plain.count >= 32 { plain = plain.dropFirst(32) }
                value = String(decoding: plain, as: UTF8.self)
            }
            out.append(Cookie(
                name: name, value: value, host: String(cString: sqlite3_column_text(stmt, 3)),
                path: String(cString: sqlite3_column_text(stmt, 4)),
                secure: sqlite3_column_int(stmt, 5) != 0, httpOnly: sqlite3_column_int(stmt, 6) != 0,
                expires: sqlite3_column_int64(stmt, 7)))
        }
        return out
    }
}

public enum ClaudeWebError: LocalizedError {
    case noActiveOrgCookie

    public var errorDescription: String? {
        String(localized: "Claude has not opened a workspace of this account yet. Open it once in Claude, then switch here.")
    }
}
