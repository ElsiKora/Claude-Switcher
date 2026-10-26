import AppKit
import SwiftUI
import SwitcherCore

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--status") {
            StatusCommand.run()
        }
        if CommandLine.arguments.contains("--probe-connectors") {
            ProbeConnectorsCommand.run()
        }
        if CommandLine.arguments.contains("--probe-orgs") {
            ProbeOrgsCommand.run()
        }
        ClaudeSwitcherApp.main()
    }
}

struct ClaudeSwitcherApp: App {
    static let isDemo = CommandLine.arguments.contains("--demo")
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
                .environment(model)
        } label: {
            StatusLabel(model: model, delegate: delegate)
        }
        .menuBarExtraStyle(.window)

        Window("Claude Switcher", id: MainWindow.id) {
            MainWindow()
                .environment(model)
        }
        .defaultSize(width: 1040, height: 760)
        .windowResizability(.contentMinSize)
        // A Dock app: the window opens with it (StatusLabel opens it, so it
        // keeps its saved size) and stays until it is closed; the menu bar
        // item and Dock icon bring it back.
        .defaultLaunchBehavior(.suppressed)

        Window("Welcome to Claude Switcher", id: "welcome") {
            WelcomeView()
                .environment(model)
                .containerBackground(.thinMaterial, for: .window)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(CommandLine.arguments.contains("--welcome") ? .presented : .suppressed)

        // `--demo` shows the menu bar panel in a window, for screenshots.
        Window("Panel preview", id: "panel") {
            MenuPanel()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(Self.isDemo ? .presented : .suppressed)

        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates\u{2026}") { Task { await model.checkForUpdatesNow() } }
                    .disabled(ClaudeSwitcherApp.isDemo)
            }
            // Settings live in the main window, so ⌘, opens that page instead of a window of their own.
            CommandGroup(replacing: .appSettings) {
                Button("Settings\u{2026}") { model.showSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

/// Opening the app again, from the Dock, Finder or Spotlight, shows its
/// window. The Dock icon is there while a window is: closing the last one
/// leaves the app in the menu bar only, the way menu bar apps do.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var openMainWindow: (() -> Void)?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openMainWindow?()
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let closing = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let closing, Self.isAppWindow(closing) else { return }
                // After the close: no other window of the app left, so no Dock icon.
                DispatchQueue.main.async {
                    if !NSApp.windows.contains(where: { $0 !== closing && $0.isVisible && Self.isAppWindow($0) }) {
                        NSApp.setActivationPolicy(.accessory)
                    }
                }
            }
        }
    }

    /// A window of its own (main, welcome), not the menu bar panel, a sheet or a sign-in popup.
    @MainActor
    static func isAppWindow(_ window: NSWindow) -> Bool {
        guard let id = window.identifier?.rawValue else { return false }
        return id.hasPrefix(MainWindow.id) || id.hasPrefix("welcome")
    }

    /// Before a window opens: the Dock icon comes back with it.
    @MainActor
    static func showInDock() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }
}

/// The menu bar label. It lives as long as the app, so it also starts the
/// model and hands the delegate a way to open the window.
struct StatusLabel: View {
    let model: AppModel
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: StatusIcon.image(for: model))
            .accessibilityLabel("Claude Switcher")
            .task {
                delegate.openMainWindow = {
                    AppDelegate.showInDock()
                    openWindow(id: MainWindow.id)
                    NSApp.activate()
                }
                model.showMainWindow = delegate.openMainWindow
                model.showWelcome = {
                    AppDelegate.showInDock()
                    openWindow(id: "welcome")
                    NSApp.activate()
                }
                model.start()
                // A Dock app shows its window when it starts, restored or not.
                if !NSApp.windows.contains(where: { $0.isVisible && $0.identifier?.rawValue.hasPrefix(MainWindow.id) == true }) {
                    openWindow(id: MainWindow.id)
                }
                if ClaudeSwitcherApp.isDemo, CommandLine.arguments.contains("--hud") { model.showDemoHUD() }
            }
    }
}

/// The menu bar icon: the signed-in account's two limits as two rings, the
/// 5-hour limit outside and the week inside, in the menu bar's own color
/// until one of them gets full.
enum StatusIcon {
    @MainActor
    static func image(for model: AppModel) -> NSImage {
        let usage = model.activeAccount?.usage?.current(at: model.now)
        return image(session: usage?.session, week: usage?.weekly, threshold: model.state.threshold, busy: model.isBusy)
    }

    static func image(session: Double?, week: Double?, threshold: Double, busy: Bool) -> NSImage {
        let peak = max(session ?? 0, week ?? 0)
        let color: NSColor? = switch peak {
        case threshold...: .systemRed
        case 75...: .systemOrange
        default: nil
        }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let ink = color ?? .black
            func ring(_ inset: CGFloat, _ fraction: Double, width: CGFloat) {
                let r = rect.insetBy(dx: inset, dy: inset)
                let track = NSBezierPath(ovalIn: r)
                track.lineWidth = width
                ink.withAlphaComponent(0.28).setStroke()
                track.stroke()
                guard fraction > 0 else { return }
                let arc = NSBezierPath()
                arc.appendArc(withCenter: NSPoint(x: r.midX, y: r.midY), radius: r.width / 2,
                              startAngle: 90, endAngle: 90 - 360 * min(fraction, 1), clockwise: true)
                arc.lineWidth = width
                arc.lineCapStyle = .round
                ink.setStroke()
                arc.stroke()
            }
            if busy {
                ring(1.6, 0.3, width: 2.2)
                ring(5.4, 0.3, width: 2.2)
            } else {
                ring(1.6, (session ?? 0) / 100, width: 2.2)
                ring(5.4, (week ?? 0) / 100, width: 2.2)
            }
            return true
        }
        image.isTemplate = color == nil
        return image
    }
}

/// `ClaudeSwitcher --status` prints every saved account with its usage and exits.
enum StatusCommand {
    static func run() -> Never {
        let engine = SwitchEngine()
        let state = engine.store.loadState()
        let active = try? engine.desktop.activeAccount()
        let api = AnthropicAPI(userAgent: "ClaudeSwitcher/\(AppInfo.version)")
        let ids = Set(state.accounts.map(\.id)).union(active.map { [$0] } ?? [])
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for id in ids.sorted() {
                let url = id == active ? engine.desktop.configURL : engine.store.signInDir(id).appending(path: "config.json")
                let mark = id == active ? "*" : " "
                do {
                    let token = try TokenCache.accessToken(fromEncrypted: ClaudeDesktop.tokenCache(in: url), account: id)
                    let profile = try await api.profile(token: token)
                    let u = try await api.usage(token: token)
                    print("\(mark) \(profile.name.isEmpty ? profile.email : profile.name) (\(profile.plan))  5h \(Int(u.session))%  week \(Int(u.weekly))%  week resets \(u.weeklyReset?.formatted() ?? "-")")
                } catch {
                    print("\(mark) \(id.prefix(8))  \(error.localizedDescription)")
                }
            }
            done.signal()
        }
        done.wait()
        exit(0)
    }
}

/// `ClaudeSwitcher --probe-connectors` reads, and only reads, each account's
/// connectors and the permissions of one connector's tools from claude.ai,
/// to show whether claude.ai answers this app. Prints names and status codes.
/// `ClaudeSwitcher --probe-orgs` reads, and only reads, each saved
/// account's organizations: what claude.ai lists for its session, which
/// organizations its saved sign-in holds tokens for (key names only, never
/// a token), and the organization claude.ai last had active.
enum ProbeOrgsCommand {
    static func run() -> Never {
        let engine = SwitchEngine()
        let state = engine.store.loadState()
        let active = try? engine.desktop.activeAccount()
        let done = DispatchSemaphore(value: 0)
        let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
        func short(_ s: String) -> String { String(s.prefix(8)) }
        Task.detached {
            for account in state.accounts {
                let isActive = account.id == active
                let dir = engine.store.signInDir(account.id)
                let cookies = isActive ? engine.desktop.cookieFiles[0] : dir.appending(path: "Cookies")
                let config = isActive ? engine.desktop.configURL : dir.appending(path: "config.json")
                print("== \(account.displayName) \(short(account.id)) (\(isActive ? "active" : "saved")), saved org \(short(account.org))")
                if let keys = try? TokenCache.keys(fromEncrypted: ClaudeDesktop.tokenCache(in: config)) {
                    for key in keys {
                        // acct:<account>|<client>:<org>:<audience>:<scopes>; ids shortened, scopes kept.
                        let parts = key.split(separator: "|", maxSplits: 1)
                        let rest = parts.count > 1 ? parts[1].split(separator: ":").map(String.init) : []
                        print("  token for org \(rest.count > 1 ? short(rest[1]) : "?") scopes \(rest.dropFirst(3).joined(separator: ":"))")
                    }
                } else { print("  token cache: unreadable") }
                print("  lastActiveOrg: \((try? ClaudeWeb.cookie("lastActiveOrg", in: cookies)).flatMap { $0 }.map(short) ?? "-")")
                // `--roundtrip`: write each workspace into a copy of the cookie store and read it back.
                if CommandLine.arguments.contains("--roundtrip"), let orgs = account.orgs {
                    let copy = FileManager.default.temporaryDirectory.appending(path: "claude-switcher-roundtrip-\(UUID().uuidString)")
                    defer { try? FileManager.default.removeItem(at: copy) }
                    if (try? FileManager.default.copyItem(at: cookies, to: copy)) != nil {
                        for org in orgs {
                            do {
                                try ClaudeWeb.setActiveOrg(org.id, in: copy)
                                let back = try ClaudeWeb.cookie("lastActiveOrg", in: copy)
                                print("  roundtrip \(org.label): wrote \(short(org.id)), read \(back.map(short) ?? "nil") \(back == org.id ? "OK" : "MISMATCH")")
                            } catch { print("  roundtrip \(org.label): \(error.localizedDescription)") }
                        }
                    }
                }
                do {
                    let web = try ClaudeWeb(cookieStore: cookies, userAgent: ua)
                    let orgs = try await web.list("/api/organizations")
                    for o in orgs {
                        let safe = o.filter { ["name", "capabilities", "rate_limit_tier", "billing_type", "raven_type", "active_flags"].contains($0.key) }
                        print("  org \((o["uuid"] as? String).map(short) ?? "?"): \(safe)")
                        guard CommandLine.arguments.contains("--usage"), let uuid = o["uuid"] as? String else { continue }
                        let (us, ub) = try await web.get("/api/organizations/\(uuid)/usage")
                        let obj = (try? JSONSerialization.jsonObject(with: ub)) as? [String: Any]
                        let windows = obj?.compactMapValues { ($0 as? [String: Any])?.filter { ["utilization", "resets_at", "is_enabled", "used_credits", "monthly_limit", "currency"].contains($0.key) } }
                        print("    usage HTTP \(us): keys \(obj?.keys.sorted() ?? []); \(windows ?? [:])")
                    }
                } catch { print("  /api/organizations: \(error)") }
            }
            done.signal()
        }
        done.wait()
        exit(0)
    }
}

enum ProbeConnectorsCommand {
    static func run() -> Never {
        let engine = SwitchEngine()
        let state = engine.store.loadState()
        let active = try? engine.desktop.activeAccount()
        let done = DispatchSemaphore(value: 0)
        let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
        Task.detached {
            for account in state.accounts {
                let store = account.id == active
                    ? engine.desktop.cookieFiles[0]
                    : engine.store.signInDir(account.id).appending(path: "Cookies")
                print("== \(account.displayName) (\(account.id == active ? "active" : "saved"))")
                do {
                    let web = try ClaudeWeb(cookieStore: store, userAgent: ua)
                    let (status, body) = try await web.get("/api/organizations/\(account.org)/mcp/remote_servers")
                    print("  remote_servers: HTTP \(status), \(body.count) bytes")
                    guard status == 200, let list = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]] else {
                        print("  body starts: \(String(decoding: body.prefix(160), as: UTF8.self))")
                        continue
                    }
                    print("  \(list.count) connectors; fields: \(list.first.map { $0.keys.sorted() } ?? [])")
                    for s in list { print("   - \(s["name"] ?? "?")  \(s["url"] ?? "")") }
                    for s in list {
                        guard let id = s["uuid"] as? String else { continue }
                        let (ps, pb) = try await web.get("/api/organizations/\(account.org)/mcp/remote_servers/\(id)/tool_policies?mark_default_blocks=true")
                        print("  policies \(s["name"] ?? "?") [dir \((s["mcp_directory_server_uuid"] as? String).map { String($0.prefix(8)) } ?? "-") src \(s["installation_source"] ?? "-") oauth \(s["has_custom_oauth_credentials"] ?? "-")]: HTTP \(ps) \(String(decoding: pb.prefix(200), as: UTF8.self))")
                    }
                    let (cs, cb) = try await web.get("/api/organizations/\(account.org)/mcp/remote_servers_with_connection")
                    if let conn = try? JSONSerialization.jsonObject(with: cb) {
                        let first: [String: Any]? = (conn as? [[String: Any]])?.first ?? (conn as? [String: Any])
                        print("  with_connection HTTP \(cs): type \(type(of: conn)); first keys: \(first?.keys.sorted() ?? [])")
                        for item in (conn as? [[String: Any]]) ?? [] {
                            let c = item.filter { ["name", "connected", "is_connected", "connection_status", "status", "auth_status", "sign_in_pending"].contains($0.key) }
                            print("     \(c)")
                        }
                    } else { print("  with_connection HTTP \(cs) \(String(decoding: cb.prefix(200), as: UTF8.self))") }
                    for path in ["/plugins/list-plugins?limit=200", "/plugins/account-list-plugins?limit=200", "/skills/list-skills"] {
                        let (ps, pb) = try await web.get("/api/organizations/\(account.org)\(path)")
                        let obj = try? JSONSerialization.jsonObject(with: pb)
                        let items = (obj as? [[String: Any]]) ?? ((obj as? [String: Any])?.values.compactMap { $0 as? [[String: Any]] }.first) ?? []
                        print("  \(path) HTTP \(ps): \(items.count) items; top keys \((obj as? [String: Any])?.keys.sorted() ?? []); item keys \(items.first?.keys.sorted() ?? [])")
                        for it in items.prefix(14) {
                            let c = it.filter { ["id", "name", "display_name", "displayName", "enabled", "installed", "is_enabled", "marketplace_name", "source", "creator_type", "creatorType", "installation_preference"].contains($0.key) }
                            print("     \(c)")
                        }
                    }
                    let (as_, ab) = try await web.get("/api/account")
                    if let acct = try? JSONSerialization.jsonObject(with: ab) as? [String: Any],
                       let settings = acct["settings"] as? [String: Any] {
                        let tools = settings["enabled_mcp_tools"]
                        let desc = (tools as? [String: Any]).map { "\($0.count) entries, e.g. \(Array($0.prefix(3)))" } ?? String(describing: tools).prefix(200).description
                        print("  /api/account HTTP \(as_): enabled_mcp_tools = \(desc)")
                    } else {
                        print("  /api/account HTTP \(as_)")
                    }
                } catch {
                    print("  failed: \(error.localizedDescription)")
                }
            }
            done.signal()
        }
        done.wait()
        exit(0)
    }
}
