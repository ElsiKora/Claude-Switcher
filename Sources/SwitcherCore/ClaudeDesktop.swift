public import Foundation

/// The data folder of the Claude desktop app and the sign-in it holds.
public struct ClaudeDesktop: Sendable {
    public static let bundleIdentifier = "com.anthropic.claudefordesktop"

    /// The `config.json` members that belong to the signed-in account.
    /// Everything else in `config.json` is app state shared by all accounts.
    public static let authKeys = ["oauth:tokenCache", "oauth:tokenCacheV2", "lastKnownAccountUuid"]

    public let root: URL

    public init(root: URL) { self.root = root }

    public static var standard: ClaudeDesktop {
        ClaudeDesktop(root: URL.applicationSupportDirectory.appending(path: "Claude", directoryHint: .isDirectory))
    }

    public var configURL: URL { root.appending(path: "config.json") }
    public var sessionsRoot: URL { root.appending(path: "claude-code-sessions", directoryHint: .isDirectory) }
    public var spacesRoot: URL { root.appending(path: "local-agent-mode-sessions", directoryHint: .isDirectory) }

    /// The claude.ai web session. Newer Chromium builds keep it in `Network/`,
    /// the macOS app keeps it in the data folder itself. Locked while Claude runs.
    public var cookieFiles: [URL] {
        let network = root.appending(path: "Network", directoryHint: .isDirectory)
        let base = FileManager.default.fileExists(atPath: network.path) ? network : root
        return [base.appending(path: "Cookies"), base.appending(path: "Cookies-journal")]
    }

    public func readConfig() throws -> JSONObjectText {
        try JSONObjectText(contentsOf: configURL)
    }

    /// The account Claude is signed in with, nil when it shows its sign-in screen.
    public func activeAccount() throws -> String? {
        try Self.signedInAccount(of: readConfig())
    }

    static func signedInAccount(of config: JSONObjectText) -> String? {
        guard config.contains("oauth:tokenCacheV2"), let id = config.string("lastKnownAccountUuid"), !id.isEmpty else {
            return nil
        }
        return id
    }

    /// The encrypted `oauth:tokenCacheV2` value of a config file.
    public static func tokenCache(in configURL: URL) throws -> String {
        guard let value = try JSONObjectText(contentsOf: configURL).string("oauth:tokenCacheV2") else {
            throw SwitchError.noSavedSignIn
        }
        return value
    }

    // MARK: - Sign-ins

    /// Copies the current sign-in into `dir`. Claude must be closed.
    public func saveSignIn(to dir: URL) throws {
        let config = try readConfig()
        var saved = JSONObjectText.empty()
        for key in Self.authKeys {
            if let raw = config.raw(key) { try saved.set(key, raw: raw) }
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Files.writeAtomically(saved.data, to: dir.appending(path: "config.json"))
        for file in cookieFiles {
            try Files.mirror(file, to: dir.appending(path: file.lastPathComponent))
        }
    }

    /// Puts a saved sign-in back. Claude must be closed.
    public func restoreSignIn(from dir: URL) throws {
        let saved = try JSONObjectText(contentsOf: dir.appending(path: "config.json"))
        var config = try readConfig()
        for key in Self.authKeys {
            if let raw = saved.raw(key) {
                try config.set(key, raw: raw)
            } else {
                try config.remove(key)
            }
        }
        for file in cookieFiles {
            try Files.mirror(dir.appending(path: file.lastPathComponent), to: file)
        }
        try Files.writeAtomically(config.data, to: configURL)
    }

    /// Removes the current sign-in locally so Claude opens on its sign-in
    /// screen. It never signs out, which would end the saved sign-in on
    /// Anthropic's side. Claude must be closed.
    public func clearSignIn() throws {
        var config = try readConfig()
        for key in Self.authKeys { try config.remove(key) }
        for file in cookieFiles where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        try Files.writeAtomically(config.data, to: configURL)
    }

    // MARK: - Backups

    /// The single files a switch changes.
    public var switchedFiles: [URL] {
        [configURL, root.appending(path: "claude_desktop_config.json"), root.appending(path: "ccd-session-presets.json")] + cookieFiles
    }

    /// The files a switch changes, copied before it touches them.
    public func backup(into root: URL, keep: Int = 10) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let dir = root.appending(path: formatter.string(from: .now), directoryHint: .isDirectory)
        for file in switchedFiles {
            try Files.mirror(file, to: dir.appending(path: file.lastPathComponent))
        }
        Files.prune(root, keep: keep)
        return dir
    }

    /// Undoes a switch that failed halfway.
    public func restore(backup dir: URL) throws {
        for file in switchedFiles {
            try Files.mirror(dir.appending(path: file.lastPathComponent), to: file)
        }
    }
}

public enum SwitchError: LocalizedError, Equatable {
    case noSavedSignIn
    case unknownAccount
    case claudeDidNotQuit
    case claudeNotInstalled
    case signedOut
    case busy

    public var errorDescription: String? {
        switch self {
        case .noSavedSignIn: String(localized: "There is no saved sign-in for this account. Add it again.")
        case .unknownAccount: String(localized: "Unknown account.")
        case .claudeDidNotQuit: String(localized: "Claude did not quit.")
        case .claudeNotInstalled: String(localized: "Claude is not installed in Applications.")
        case .signedOut: String(localized: "The sign-in has expired. Add the account again.")
        case .busy: String(localized: "Another switch is still running.")
        }
    }
}
