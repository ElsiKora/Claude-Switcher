import Foundation

/// What an account has set up on claude.ai, read live with its own web
/// session, the way claude.ai's Settings page reads it: its connectors and
/// whether each one is signed in, its enabled plugins and skills.
public struct CloudSetup: Sendable, Equatable {
    public struct Connector: Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var url: String
        public var directoryID: String?
        public var connected: Bool
        public var customOAuth: Bool

        public init(id: String, name: String, url: String, directoryID: String?, connected: Bool, customOAuth: Bool) {
            self.id = id
            self.name = name
            self.url = url
            self.directoryID = directoryID
            self.connected = connected
            self.customOAuth = customOAuth
        }
    }

    public struct Item: Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public var connectors: [Connector] = []
    public var plugins: [Item] = []
    public var skills: [Item] = []
    /// Anthropic's skills claude.ai offers this account, on or off. Not every
    /// account is offered the same ones.
    public var offeredSkills: Set<String> = []
    /// Skills someone made or uploaded, which carry their own files.
    public var customSkills: [Item] = []

    public init() {}

    public var count: Int { connectors.count + plugins.count + skills.count }

    public static func read(_ web: ClaudeWeb, org: String) async throws -> CloudSetup {
        var setup = CloudSetup()
        for s in try await web.list("/api/organizations/\(org)/mcp/remote_servers_with_connection") {
            guard let id = s["uuid"] as? String, let url = s["url"] as? String, s["anthropic_managed"] as? Bool != true else { continue }
            setup.connectors.append(Connector(
                id: id, name: s["name"] as? String ?? url, url: url,
                directoryID: s["mcp_directory_server_uuid"] as? String,
                connected: s["connection_state"] as? String == "connected",
                customOAuth: s["has_custom_oauth_credentials"] as? Bool == true))
        }
        setup.connectors.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        var offset = 0
        while true {
            let page = try await web.object("/api/organizations/\(org)/plugins/list-plugins?enabled_only=true&limit=1000&offset=\(offset)")
            let plugins = page["plugins"] as? [[String: Any]] ?? []
            for p in plugins where p["enabled"] as? Bool == true {
                guard let id = p["id"] as? String else { continue }
                setup.plugins.append(Item(id: id, name: p["display_name"] as? String ?? p["name"] as? String ?? id))
            }
            guard page["has_more"] as? Bool == true, !plugins.isEmpty, offset < 10_000 else { break }
            offset += plugins.count
        }
        setup.plugins.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let skills = try await web.object("/api/organizations/\(org)/skills/list-skills")["skills"] as? [[String: Any]] ?? []
        for s in skills {
            guard let id = s["id"] as? String else { continue }
            let item = Item(id: id, name: s["display_name"] as? String ?? s["name"] as? String ?? id)
            if s["creator_type"] as? String != "anthropic" {
                setup.customSkills.append(item)
            } else {
                setup.offeredSkills.insert(id)
                if s["enabled"] as? Bool == true { setup.skills.append(item) }
            }
        }
        return setup
    }

    /// What this account lacks compared with `reference`.
    public struct Gaps: Sendable, Equatable {
        public var missingConnectors: [Connector] = []
        /// Connectors that are there but wait for their sign-in.
        public var signIn: [Connector] = []
        public var plugins: [Item] = []
        public var skills: [Item] = []
        /// Skills the reference has on that claude.ai does not offer this account.
        public var unavailableSkills: [Item] = []
        /// The reference's own skills; these are uploaded by hand.
        public var customSkills: [Item] = []

        public var count: Int { missingConnectors.count + signIn.count + plugins.count + skills.count + customSkills.count }
        /// What Copy Setup can do something about.
        public var copyable: Int { missingConnectors.count + plugins.count + skills.count }
    }

    public func gaps(from reference: CloudSetup) -> Gaps {
        var gaps = Gaps()
        for c in reference.connectors {
            if let mine = connectors.first(where: { Self.sameURL($0.url, c.url) }) {
                if !mine.connected { gaps.signIn.append(mine) }
            } else {
                gaps.missingConnectors.append(c)
            }
        }
        // Connectors of this account the reference does not have still need their sign-in too.
        gaps.signIn += connectors.filter { c in !c.connected && !reference.connectors.contains { Self.sameURL($0.url, c.url) } }
        let myPlugins = Set(plugins.map(\.id))
        gaps.plugins = reference.plugins.filter { !myPlugins.contains($0.id) }
        let mySkills = Set(skills.map(\.id))
        let wanted = reference.skills.filter { !mySkills.contains($0.id) }
        gaps.skills = wanted.filter { offeredSkills.contains($0.id) }
        gaps.unavailableSkills = wanted.filter { !offeredSkills.contains($0.id) }
        let myCustom = Set(customSkills.map(\.name))
        gaps.customSkills = reference.customSkills.filter { !myCustom.contains($0.name) }
        return gaps
    }

    static func sameURL(_ a: String?, _ b: String) -> Bool {
        func norm(_ s: String) -> String {
            var s = s.lowercased()
            while s.hasSuffix("/") { s.removeLast() }
            return s
        }
        return a.map(norm) == norm(b)
    }
}

/// Brings another account up to the reference account's claude.ai setup,
/// through the same calls claude.ai's Settings page makes:
/// - adds missing connectors (directory ones by their directory id, custom
///   ones by URL) and copies the tool permissions chosen for them;
/// - moves the tool switches, approvals ("always allow") and blocks onto the
///   new connectors' ids;
/// - turns on the plugins and skills the reference has on.
/// Nothing is removed or turned off. Signing in to each connector stays with
/// the person, and so does uploading the reference's own skills. A custom
/// connector with its own OAuth client is added without it: claude.ai never
/// shows the secret.
public struct SetupCopy: Sendable {
    public struct Result: Sendable, Equatable {
        public var connectors: [String] = []
        public var plugins: [String] = []
        public var skills: [String] = []
        public var failed: [String] = []
        public var needOAuthClient: [String] = []
        public var toolSettings = 0

        public var changes: Int { connectors.count + plugins.count + skills.count + toolSettings }
    }

    let reference: ClaudeWeb
    let referenceOrg: String
    let target: ClaudeWeb
    let targetOrg: String

    public init(reference: ClaudeWeb, referenceOrg: String, target: ClaudeWeb, targetOrg: String) {
        self.reference = reference
        self.referenceOrg = referenceOrg
        self.target = target
        self.targetOrg = targetOrg
    }

    public func run() async throws -> Result {
        var result = Result()
        let theirs = try await CloudSetup.read(reference, org: referenceOrg)
        let mine = try await CloudSetup.read(target, org: targetOrg)

        // Connectors, and their ids on both sides for the tool settings.
        var ids: [String: String] = [:]
        for c in theirs.connectors {
            if let existing = mine.connectors.first(where: { CloudSetup.sameURL($0.url, c.url) }) {
                ids[c.id] = existing.id
                continue
            }
            var body: [String: Any] = ["name": c.name, "url": c.url, "attestations": [Any]()]
            if let directory = c.directoryID { body["mcp_directory_server_uuid"] = directory }
            let (status, data) = try await target.send(
                "POST", "/api/organizations/\(targetOrg)/mcp/remote_servers", json: body)
            guard (200..<300).contains(status),
                  let created = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newID = created["uuid"] as? String else {
                result.failed.append("\(c.name) (HTTP \(status))")
                continue
            }
            ids[c.id] = newID
            result.connectors.append(c.name)
            if c.customOAuth { result.needOAuthClient.append(c.name) }
        }

        // Tool permissions someone chose on a connector.
        for (from, to) in ids {
            let policies = (try? await reference.list(
                "/api/organizations/\(referenceOrg)/mcp/remote_servers/\(from)/tool_policies?mark_default_blocks=true")) ?? []
            for policy in policies {
                guard let tool = policy["tool_name"] as? String, let permission = policy["max_permission"] as? String,
                      (policy["source"] as? String).map({ $0 == "admin" }) ?? true else { continue }
                let encoded = tool.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? tool
                let (s, _) = try await target.send(
                    "PUT", "/api/organizations/\(targetOrg)/mcp/remote_servers/\(to)/tool_policies/\(encoded)",
                    json: ["max_permission": permission])
                if (200..<300).contains(s) { result.toolSettings += 1 }
            }
        }

        // Tool switches, approvals and blocks of the account.
        let their = try await toolSettings(reference)
        let current = try await toolSettings(target)
        var patch: [String: Any] = [:]
        for (key, value) in their {
            guard let moved = Self.move(key, ids), current[moved] == nil else { continue }
            patch[moved] = value
        }
        if !patch.isEmpty {
            let (s, _) = try await target.send("PATCH", "/api/account/settings", json: ["enabled_mcp_tools": patch])
            if (200..<300).contains(s) { result.toolSettings += patch.count } else { result.failed.append("tool settings (HTTP \(s))") }
        }

        // Plugins and skills the reference has on.
        let myPlugins = Set(mine.plugins.map(\.id))
        for p in theirs.plugins where !myPlugins.contains(p.id) {
            let (s, _) = try await target.send(
                "PUT", "/api/organizations/\(targetOrg)/plugins/\(p.id)/enabled", json: ["enabled": true])
            if (200..<300).contains(s) { result.plugins.append(p.name) } else { result.failed.append("\(p.name) (HTTP \(s))") }
        }
        let mySkills = Set(mine.skills.map(\.id))
        for k in theirs.skills where !mySkills.contains(k.id) && mine.offeredSkills.contains(k.id) {
            let (s, _) = try await target.send(
                "POST", "/api/organizations/\(targetOrg)/skills/enable-skill", json: ["skill_id": k.id])
            if (200..<300).contains(s) { result.skills.append(k.name) } else { result.failed.append("\(k.name) (HTTP \(s))") }
        }
        return result
    }

    func toolSettings(_ web: ClaudeWeb) async throws -> [String: Any] {
        (try await web.object("/api/account")["settings"] as? [String: Any])?["enabled_mcp_tools"] as? [String: Any] ?? [:]
    }

    /// The same setting for the target's copy of the connector. Keys are
    /// `<server>:<tool>` (switch), `<server>:<tool>-<hash>` (approval) and
    /// `blocked=<server>%3A<tool>` (block).
    static func move(_ key: String, _ ids: [String: String]) -> String? {
        if key.hasPrefix("blocked=") {
            let inner = String(key.dropFirst("blocked=".count))
            guard let colon = inner.range(of: "%3A"), let to = ids[String(inner[..<colon.lowerBound])] else { return nil }
            return "blocked=" + to + inner[colon.lowerBound...]
        }
        guard let colon = key.firstIndex(of: ":"), let to = ids[String(key[..<colon])] else { return nil }
        return to + key[colon...]
    }
}
