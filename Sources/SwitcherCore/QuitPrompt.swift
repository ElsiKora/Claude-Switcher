public import AppKit
import ApplicationServices

/// Claude's "Claude is still working" prompt. Claude asks it whenever it is
/// told to quit while chats run, from a signal too, and waits for an answer
/// while the chats go on. The switcher answers "Quit anyway" through
/// Accessibility, the way the person would: Claude then runs its full
/// shutdown, which saves every chat and records the timers it stops.
@MainActor
public enum QuitPrompt {
    /// Whether macOS lets the switcher press buttons in Claude.
    public static var isAllowed: Bool { AXIsProcessTrusted() }

    /// Asks macOS to let the switcher press buttons in Claude; macOS shows
    /// its own prompt that leads to Privacy & Security → Accessibility.
    public static func requestAccess() {
        let prompt = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    /// Presses "Quit anyway" in Claude's quit prompt. Returns whether it did.
    public static func answer(pid: pid_t, title: String) -> Bool {
        promptButtons(pid: pid).contains { button in
            string(button, kAXTitleAttribute) == title && AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
        }
    }

    /// The titles of the buttons in a prompt `pid` shows, for `--probe-quit-prompt`.
    public static func promptButtonTitles(pid: pid_t) -> [String] {
        promptButtons(pid: pid).map { string($0, kAXTitleAttribute) ?? "" }
    }

    /// The buttons of the sheets and dialogs `pid` shows. The prompt is a
    /// sheet on Claude's window, or a window of its own when no window
    /// shows; the chats' web content is never searched.
    private static func promptButtons(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        return elements(app, kAXWindowsAttribute).flatMap { window in
            var places = elements(window, kAXChildrenAttribute).filter { string($0, kAXRoleAttribute) == kAXSheetRole }
            if string(window, kAXSubroleAttribute) != kAXStandardWindowSubrole { places.append(window) }
            return places.flatMap { buttons(in: $0, depth: 3) }
        }
    }

    /// The title `quit` presses, for `--probe-quit-prompt`.
    public static func quitAnywayTitle(desktop: ClaudeDesktop = .standard) -> String {
        quitAnywayTitle(app: NSWorkspace.shared.urlForApplication(withBundleIdentifier: ClaudeDesktop.bundleIdentifier), desktop: desktop)
    }

    /// The prompt's "Quit anyway" in the language Claude shows, from Claude's own strings.
    static func quitAnywayTitle(app: URL?, desktop: ClaudeDesktop) -> String {
        let fallback = "Quit anyway"
        guard let resources = app?.appending(path: "Contents/Resources") else { return fallback }
        let locale = (try? desktop.readConfig())?.string("locale") ?? "en-US"
        let language = String(locale.prefix { $0 != "-" && $0 != "_" })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: resources.path)) ?? []
        let candidates = ["\(locale).json", "\(language).json"]
            + files.filter { $0.hasPrefix("\(language)-") && $0.hasSuffix(".json") }
            + ["en-US.json"]
        for name in candidates {
            guard let data = try? Data(contentsOf: resources.appending(path: name)),
                  let strings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = strings["j17BCr6YjW"] as? String else { continue }
            return title
        }
        return fallback
    }

    private static func buttons(in element: AXUIElement, depth: Int) -> [AXUIElement] {
        guard depth > 0 else { return [] }
        return elements(element, kAXChildrenAttribute).flatMap { child in
            string(child, kAXRoleAttribute) == kAXButtonRole ? [child] : buttons(in: child, depth: depth - 1)
        }
    }

    private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
