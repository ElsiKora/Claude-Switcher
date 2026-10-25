public import Foundation

/// Claude drops an account's permission settings (folder permission modes,
/// permission mode acknowledgements) once it sees that account signed out,
/// as it does while Add Account shows its sign-in screen. The switcher keeps
/// a copy of each account's settings next to its saved sign-in and puts back
/// whatever went missing when Claude is switched to that account again.
/// Claude must be closed.
public enum AccountPrefs {
    static let fileName = "prefs.json"
    /// Per-chat state tied to a moment, not a setting.
    static let skipped: Set<String> = ["autoResumeRateLimit"]

    /// Adds the account's current settings to the copy in `dir`; current values win.
    public static func capture(in desktop: ClaudeDesktop, account: String, into dir: URL) throws {
        guard let prefs = try preferences(desktop) else { return }
        var snapshot = try read(dir) ?? [:]
        var epitaxy = snapshot["epitaxyPrefs"] as? [String: Any] ?? [:]
        for (key, value) in prefs["epitaxyPrefs"] as? [String: Any] ?? [:] {
            guard let prefix = prefix(of: key, account: account) else { continue }
            if let live = value as? [String: Any], let kept = epitaxy[prefix] as? [String: Any] {
                epitaxy[prefix] = kept.merging(live) { _, new in new }
            } else {
                epitaxy[prefix] = value
            }
        }
        var maps = snapshot["byAccount"] as? [String: Any] ?? [:]
        for name in SettingsMirror.byAccountMaps {
            if let value = (prefs[name] as? [String: Any])?[account] { maps[name] = value }
        }
        snapshot["epitaxyPrefs"] = epitaxy
        snapshot["byAccount"] = maps
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try SettingsMirror.write(snapshot, to: dir.appending(path: fileName))
    }

    /// Puts back settings of the account that Claude no longer has. Settings
    /// Claude still has are left as they are. Returns whether anything came back.
    @discardableResult
    public static func restore(in desktop: ClaudeDesktop, account: String, from dir: URL) throws -> Bool {
        let url = desktop.root.appending(path: "claude_desktop_config.json")
        guard let snapshot = try read(dir), var root = try SettingsMirror.readObject(url),
              var prefs = root["preferences"] as? [String: Any] else { return false }
        var changed = false
        var epitaxy = prefs["epitaxyPrefs"] as? [String: Any] ?? [:]
        for (prefix, value) in snapshot["epitaxyPrefs"] as? [String: Any] ?? [:] {
            let key = "\(prefix).\(account)"
            if let kept = value as? [String: Any], let live = epitaxy[key] as? [String: Any] {
                let merged = kept.merging(live) { _, current in current }
                if merged.count != live.count { epitaxy[key] = merged; changed = true }
            } else if epitaxy[key] == nil {
                epitaxy[key] = value
                changed = true
            }
        }
        for (name, value) in snapshot["byAccount"] as? [String: Any] ?? [:] {
            var map = prefs[name] as? [String: Any] ?? [:]
            if map[account] == nil {
                map[account] = value
                prefs[name] = map
                changed = true
            }
        }
        guard changed else { return false }
        prefs["epitaxyPrefs"] = epitaxy
        root["preferences"] = prefs
        try SettingsMirror.write(root, to: url)
        return true
    }

    static func prefix(of key: String, account: String) -> String? {
        let suffix = ".\(account)"
        guard key.hasSuffix(suffix) else { return nil }
        let prefix = String(key.dropLast(suffix.count))
        return skipped.contains(prefix) ? nil : prefix
    }

    static func preferences(_ desktop: ClaudeDesktop) throws -> [String: Any]? {
        try SettingsMirror.readObject(desktop.root.appending(path: "claude_desktop_config.json"))?["preferences"] as? [String: Any]
    }

    static func read(_ dir: URL) throws -> [String: Any]? {
        try SettingsMirror.readObject(dir.appending(path: fileName))
    }
}
