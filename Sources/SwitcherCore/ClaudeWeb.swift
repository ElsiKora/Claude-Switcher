public import Foundation
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

        let sql = "SELECT name, value, encrypted_value FROM cookies WHERE host_key = 'claude.ai' OR host_key = '.claude.ai'"
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
            out.append(Cookie(name: name, value: value))
        }
        return out
    }
}
