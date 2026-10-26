import Foundation
import SwitcherCore

/// Made-up accounts for `--demo`, which shows the design without touching Claude.
enum Demo {
    /// `--select=<account id>|analytics|chats|settings|activity` opens the window on that page.
    @MainActor static var initialSelection: SidebarItem? {
        guard let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--select=") })?.dropFirst("--select=".count)
        else { return nil }
        switch arg {
        case "settings": return .settings
        case "analytics": return .analytics
        case "chats": return .chats
        case "activity": return .activity
        default: return .account(String(arg))
        }
    }

    static let state: SwitcherState = {
        var st = SwitcherState()
        let now = Date.now
        func account(_ id: String, _ name: String, _ email: String, _ plan: String, _ s: Double, _ w: Double, sessionIn: Double, weekIn: Double) -> Account {
            var a = Account(profile: Profile(accountID: id, organizationID: "org-\(id)", name: name, email: email, plan: plan))
            a.usage = Usage(session: s, sessionReset: now.addingTimeInterval(sessionIn * 3600), weekly: w,
                            weeklyReset: now.addingTimeInterval(weekIn * 3600), checkedAt: now)
            return a
        }
        st.accounts = [
            account("a1", "Alex Rivera", "alex@example.com", "Max", 82, 61, sessionIn: 1.5, weekIn: 70),
            account("a2", "Studio", "studio@example.com", "Max", 8, 23, sessionIn: 4, weekIn: 30),
            account("a3", "Side project", "side@example.com", "Pro", 47, 91, sessionIn: 2, weekIn: 110),
            // A free account: shown, never rotated to.
            account("a4", "Old free", "free@example.com", "", 0, 0, sessionIn: 5, weekIn: 160),
        ]
        st.accounts[0].usage?.extra = ExtraUsage(enabled: true, usedCents: 4_210, limitCents: 20_000, currency: "USD")
        st.accounts[1].usage?.extra = ExtraUsage(enabled: false, usedCents: nil, limitCents: nil, currency: nil)
        // Studio is in a team too: two workspaces, Team open.
        var personal = Org(id: "org-a2p", name: "Studio's Organization", kind: .personal)
        personal.usage = Usage(session: 0, sessionReset: nil, weekly: 12, weeklyReset: now.addingTimeInterval(80 * 3600), checkedAt: now)
        var team = Org(id: "org-a2", name: "Acme", kind: .team)
        team.usage = st.accounts[1].usage
        st.accounts[1].orgs = [personal, team]
        st.accounts[1].plan = "Team"
        // A different account every couple of days, for the analytics page.
        var timeline = AccountTimeline()
        let ids = ["a2", "a3", "a1"]
        for day in stride(from: 30, through: 0, by: -2) {
            timeline.record(ids[(day / 2) % 3], at: now.addingTimeInterval(-Double(day) * 86_400 - 3_600))
        }
        st.timeline = timeline
        // Extra usage billed to Alex Rivera over the last days, month to date as claude.ai reports it.
        var monthToDate = 0.0
        for daysAgo in stride(from: 9, through: 0, by: -1) {
            // Matches the extra-usage spans below: billed at API prices.
            monthToDate += [0, 0, 0, 0, 0, 2240, 4000, 0, 0, 0][9 - daysAgo]
            st.extraByDay["a1", default: [:]][ExtraLedger.dayKey(now.addingTimeInterval(-Double(daysAgo) * 86_400))] = monthToDate
        }
        st.accounts[0].usage?.extra?.usedCents = monthToDate
        // Alex Rivera ran past its plan for part of a few days.
        var track = ExtraTrack(at: now.addingTimeInterval(-9 * 86_400), amount: 0)
        track.spans = [
            DateInterval(start: now.addingTimeInterval(-4 * 86_400 + 9 * 3600), duration: 5 * 3600),
            DateInterval(start: now.addingTimeInterval(-3 * 86_400 + 13 * 3600), duration: 7 * 3600),
        ]
        st.extraTracks["a1"] = track
        // The last 40 minutes of Alex Rivera's checks, for the pace and when it runs out.
        st.autoSwitch = true
        var history = UsageHistory()
        for minutesAgo in stride(from: 40, through: 0, by: -2) {
            var u = st.accounts[0].usage!
            u.session = 82 - Double(minutesAgo) * 0.55
            u.weekly = 61 - Double(minutesAgo) * 0.05
            u.checkedAt = now.addingTimeInterval(-Double(minutesAgo) * 60 - 1)
            history.add(u)
        }
        st.history["a1"] = history
        return st
    }()

    static let chatTitles = [
        "Refactor the billing service", "Fix the flaky sign-in test", "Draft the 2.0 release notes",
        "Speed up the image pipeline", "Migrate settings to SwiftData", "Review the onboarding copy",
        "Add offline mode to sync", "Profile the startup path", "Port the CLI to Swift",
        "Clean up the design tokens", "Write the API reference", "Triage crash reports",
    ]

    /// Made-up Claude Code usage over the last 30 days: hourly buckets per chat.
    static let usage: [UsageBucket: Tokens] = {
        var generator = SeededGenerator(seed: 7)
        let models = ["claude-opus-5-5", "claude-opus-5-5", "claude-sonnet-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]
        let nowHour = Int(Date.now.timeIntervalSince1970 / 3600)
        var out: [UsageBucket: Tokens] = [:]
        for hoursAgo in 0..<(30 * 24) {
            let hourOfDay = (nowHour - hoursAgo + 2) % 24
            guard hourOfDay >= 8, hourOfDay <= 23, Double.random(in: 0...1, using: &generator) < 0.7 else { continue }
            for _ in 0..<Int.random(in: 1...3, using: &generator) {
                let model = models.randomElement(using: &generator)!
                let replies = Int.random(in: 20...140, using: &generator)
                var t = Tokens()
                t.messages = replies
                t.input = replies * Int.random(in: 40...400, using: &generator)
                t.output = replies * Int.random(in: 300...1_400, using: &generator)
                t.cacheRead = replies * Int.random(in: 40_000...140_000, using: &generator)
                t.write5m = replies * Int.random(in: 500...3_000, using: &generator)
                t.write1h = replies * Int.random(in: 0...1_500, using: &generator)
                let chat = "demo-\(Int.random(in: 0..<chatTitles.count, using: &generator))"
                let bucket = UsageBucket(slot: (nowHour - hoursAgo) * 4, model: model, fast: false, longPrompt: false, conversation: chat)
                out[bucket, default: Tokens()] = out[bucket, default: Tokens()] + t
            }
        }
        return out
    }()

    @MainActor static func chats(_ report: UsageReport) -> [ChatRow] {
        let accounts = ["Alex Rivera", "Studio", "Side project"]
        let projects = ["billing", "ios-app", "website", "pipeline", "cli"]
        let statuses: [ChatRow.Status] = [.working, .working, .open, .cutOff, .idle, .open, .idle, .working, .idle, .archived, .idle, .open]
        return chatTitles.enumerated().map { i, title in
            let id = "demo-\(i)"
            let total = report.byConversation[id]
            return ChatRow(id: id, conversation: id, title: title, project: projects[i % projects.count],
                           account: accounts[i % accounts.count], model: i % 3 == 2 ? "Sonnet 5.5" : "Opus 5.5",
                           lastActive: report.lastUse[id] ?? .now, status: statuses[i],
                           tokens: total?.tokens.total ?? 0, cost: total?.cost ?? 0)
        }
        .sorted { $0.lastActive > $1.lastActive }
    }

    static let cloudSetups: [String: CloudSetup] = {
        func connector(_ name: String, _ host: String, connected: Bool = true) -> CloudSetup.Connector {
            CloudSetup.Connector(id: host, name: name, url: "https://\(host)/mcp", directoryID: nil, connected: connected, customOAuth: false)
        }
        let all = [connector("Figma", "mcp.figma.com"), connector("Linear", "mcp.linear.app"), connector("Notion", "mcp.notion.com"),
                   connector("Slack", "mcp.slack.com"), connector("Vercel", "mcp.vercel.com")]
        let plugins = [CloudSetup.Item(id: "p1", name: "Engineering"), CloudSetup.Item(id: "p2", name: "Design")]
        var full = CloudSetup()
        full.connectors = all
        full.plugins = plugins
        var partial = CloudSetup()
        partial.connectors = [all[0], connector("Linear", "mcp.linear.app", connected: false)]
        // Kept per account and workspace, like the real ones.
        return ["a1/org-a1": full, "a2/org-a2": partial, "a2/org-a2p": full, "a3/org-a3": full]
    }()

    static let activity: [Activity] = [
        Activity(date: .now.addingTimeInterval(-600), text: String(localized: "Switched to Alex Rivera."), isError: false),
        Activity(date: .now.addingTimeInterval(-3600), text: String(localized: "Brought 12 chats and 2 projects into Alex Rivera."), isError: false),
    ]
}

/// A small fixed-seed generator, so the demo looks the same every launch.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
