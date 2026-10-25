import AppKit
import SwitcherCore
import UserNotifications

/// Tells the person when an account's limit resets, and when the signed-in
/// account is nearly full while another has room, with a Switch button.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let switchAction = "SWITCH"
    static let category = "ACCOUNT"
    private var center: UNUserNotificationCenter { .current() }
    /// What was already told, so each moment is told once.
    private var told: Set<String> = []

    func start() {
        center.delegate = self
        let action = UNNotificationAction(identifier: Self.switchAction, title: String(localized: "Switch"), options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [action], intentIdentifiers: [])])
    }

    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Compares an account's usage before and after a check.
    func usageChanged(_ account: Account, from old: Usage?, to new: Usage, model: AppModel) {
        guard model.state.notify, let old else { return }
        let isActive = account.id == model.active
        if old.weekly >= 50, new.weekly + 30 <= old.weekly {
            post("week-\(account.id)-\(Int(new.checkedAt.timeIntervalSince1970 / 3600))",
                 title: String(localized: "\(account.displayName)\u{2019}s week has reset"),
                 body: String(localized: "Its weekly limit is back to \(percentText(new.weekly))."),
                 switchTo: isActive ? nil : account)
        } else if !isActive, old.session >= 80, new.session + 40 <= old.session {
            post("session-\(account.id)-\(Int(new.checkedAt.timeIntervalSince1970 / 3600))",
                 title: String(localized: "\(account.displayName) has room again"),
                 body: String(localized: "Its 5-hour limit has reset to \(percentText(new.session))."),
                 switchTo: account)
        }
        let line: Double = 90
        if isActive, old.peak < line, new.peak >= line, let best = model.suggestion {
            let u = best.usage?.current(at: model.now)
            post("full-\(account.id)-\(Int(new.checkedAt.timeIntervalSince1970 / 3600))",
                 title: String(localized: "\(account.displayName) is at \(percentText(new.peak))"),
                 body: String(localized: "\(best.displayName) has the most room: 5-hour \(percentText(u?.session)), week \(percentText(u?.weekly))."),
                 switchTo: best)
        }
    }

    private func post(_ id: String, title: String, body: String, switchTo account: Account?) {
        guard told.insert(id).inserted else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let account {
            content.categoryIdentifier = Self.category
            content.userInfo = ["account": account.id]
        }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["account"] as? String else { return }
        let tapped = response.actionIdentifier
        await MainActor.run {
            let model = AppModel.shared
            guard let account = model.state.account(id) else { return }
            if tapped == Self.switchAction {
                Task { await model.switchTo(account) }
            } else {
                model.showMainWindow?()
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
