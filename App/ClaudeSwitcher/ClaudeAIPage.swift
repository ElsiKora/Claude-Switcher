import AppKit
import SwiftUI
import SwitcherCore
import WebKit

/// A claude.ai page opened inside Claude Switcher as one account: its own
/// claude.ai session is copied into a private web view, so the page is that
/// account's whichever account Claude is signed in with. Used for the
/// Connectors page, where each connector is signed in to with claude.ai's
/// own Connect buttons.
struct ClaudeAIPage: Identifiable, Equatable {
    let account: Account
    let path: String
    var id: String { account.id + path }
}

struct ClaudeAIPageSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let page: ClaudeAIPage
    @State private var cookies: [HTTPCookie]?
    @State private var failure: String?
    @State private var reloads = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                AccountRings(account: page.account, size: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text("claude.ai as \(page.account.displayName)").font(.headline)
                    Text("Sign in to each connector with its Connect button.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { reloads += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Reload")
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            Group {
                if let cookies {
                    ClaudeWebView(path: page.path, cookies: cookies, reloads: reloads)
                } else if let failure {
                    ContentUnavailableView("Could not open claude.ai", systemImage: "exclamationmark.triangle", description: Text(failure))
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 900, idealWidth: 1000, minHeight: 640, idealHeight: 760)
        .task {
            do { cookies = try await model.webCookies(for: page.account) } catch { failure = error.localizedDescription }
        }
    }
}

/// A WKWebView with its own throwaway data store, holding only the cookies
/// it is given. Sign-in windows that a page opens (OAuth) open as windows of
/// their own and close themselves when done.
struct ClaudeWebView: NSViewRepresentable {
    let path: String
    let cookies: [HTTPCookie]
    let reloads: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.uiDelegate = context.coordinator
        let url = URL(string: path, relativeTo: ClaudeWeb.base) ?? ClaudeWeb.base
        let store = configuration.websiteDataStore.httpCookieStore
        let cookies = cookies
        Task { @MainActor in
            for cookie in cookies { await store.setCookie(cookie) }
            view.load(URLRequest(url: url))
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if context.coordinator.reloads != reloads {
            context.coordinator.reloads = reloads
            view.reload()
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKUIDelegate {
        var reloads = 0
        private var popups: [WKWebView: NSWindow] = [:]

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 560, height: 720), configuration: configuration)
            popup.uiDelegate = self
            let window = NSWindow(contentRect: popup.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = String(localized: "Sign In")
            window.contentView = popup
            window.isReleasedWhenClosed = false
            window.center()
            window.makeKeyAndOrderFront(nil)
            popups[popup] = window
            return popup
        }

        func webViewDidClose(_ webView: WKWebView) {
            popups.removeValue(forKey: webView)?.close()
        }
    }
}
