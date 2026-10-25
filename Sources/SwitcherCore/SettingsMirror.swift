import Foundation

/// Claude keeps some Claude Code settings per account: the session presets,
/// the permission mode chosen for each folder, the auto-mode consent and the
/// sidebar sections. Mirroring them from the account being left makes every
/// account look and behave the same. Claude must be closed.
public enum SettingsMirror {
    /// `preferences` maps keyed by account id.
    static let byAccountMaps = ["bypassPermissionsOptInByAccount", "coworkModelAutoFallbackByAccount"]

    /// `epitaxyPrefs` entries named `<prefix>.<account id>`. Counters and
    /// per-chat state such as `autoResumeRateLimit` stay with their account.
    static let suffixedPrefs = [
        "epitaxy-auto-mode-consented",
        "epitaxy-perm-mode-acks-v2",
        "epitaxy-folder-permission-mode-v2",
        "epitaxy-auto-default-notice-seen",
        "epitaxy-auto-entry-warning-seen",
        "epitaxy-auto-setup-band-seen",
        "epitaxy-auto-reinvite-first-block-seen",
        "epitaxy-keep-awake-band-used",
    ]

    /// Copies the settings of `source` onto `target`. Returns whether a file changed.
    @discardableResult
    public static func mirror(in desktop: ClaudeDesktop, from source: Account, to target: Account) throws -> Bool {
        guard source.id != target.id else { return false }
        let a = try mirrorPreferences(desktop.root.appending(path: "claude_desktop_config.json"), from: source, to: target)
        let b = try mirrorPresets(desktop.root.appending(path: "ccd-session-presets.json"), from: source.id, to: target.id)
        return a || b
    }

    static func mirrorPreferences(_ url: URL, from source: Account, to target: Account) throws -> Bool {
        guard var root = try readObject(url), var prefs = root["preferences"] as? [String: Any] else { return false }
        let before = prefs as NSDictionary

        for key in byAccountMaps {
            guard var map = prefs[key] as? [String: Any], let value = map[source.id] else { continue }
            map[target.id] = value
            prefs[key] = map
        }

        var epitaxy = prefs["epitaxyPrefs"] as? [String: Any] ?? [:]
        for prefix in suffixedPrefs {
            guard let value = epitaxy["\(prefix).\(source.id)"] else { continue }
            let key = "\(prefix).\(target.id)"
            if let incoming = value as? [String: Any], let existing = epitaxy[key] as? [String: Any] {
                // Folder modes: keep folders only the target knows, take the source's choice for the rest.
                epitaxy[key] = existing.merging(incoming) { _, new in new }
            } else {
                epitaxy[key] = value
            }
        }
        if var sections = epitaxy["dframe-code-sections"] as? [String: Any],
           let value = sections["\(source.id)/\(source.org)"] {
            sections["\(target.id)/\(target.org)"] = value
            epitaxy["dframe-code-sections"] = sections
        }
        if !epitaxy.isEmpty { prefs["epitaxyPrefs"] = epitaxy }

        guard !(prefs as NSDictionary).isEqual(before) else { return false }
        root["preferences"] = prefs
        try write(root, to: url)
        return true
    }

    static func mirrorPresets(_ url: URL, from source: String, to target: String) throws -> Bool {
        guard var root = try readObject(url), var byAccount = root["byAccount"] as? [String: Any],
              let value = byAccount[source] else { return false }
        if let existing = byAccount[target], (existing as AnyObject).isEqual(value) { return false }
        byAccount[target] = value
        root["byAccount"] = byAccount
        try write(root, to: url)
        return true
    }

    static func readObject(_ url: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    }

    static func write(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try Files.writeAtomically(data, to: url)
    }
}
