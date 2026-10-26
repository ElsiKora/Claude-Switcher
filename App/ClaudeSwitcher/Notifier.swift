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
    func usageChanged(_ account: Seat, from old: Usage?, to new: Usage, model: AppModel) {
        guard model.state.notify, let old else { return }
        let isActive = account.id == model.activeSeatID
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

    /// Extra usage billed today passed the amount set in Settings.
    func extraToday(_ account: Seat, amount: Double, currency: String?, day: String) {
        guard AppModel.shared.state.notify else { return }
        post("extra-\(account.id)-\(day)",
             title: String(localized: "\(account.displayName): \(money(amount, currency)) of extra usage today"),
             body: String(localized: "claude.ai has billed this beyond the plan today. Another account with room avoids more."),
             switchTo: AppModel.shared.suggestion)
    }

    /// The signed-in account is past its limit with extra usage on, and no account has room to move to.
    func billingWithoutRoom(_ account: Account, hour: Int) {
        guard AppModel.shared.state.notify else { return }
        post("billing-\(account.id)-\(hour)",
             title: String(localized: "\(account.displayName) is billing extra usage"),
             body: String(localized: "Its limit is used up and no other account has room, so claude.ai charges for what Claude does now."),
             switchTo: nil)
    }

    /// The signed-in account is nearly full and no account has room to move to.
    func noRoom(_ stuck: Policy.NoRoom, text: String) {
        guard AppModel.shared.state.notify else { return }
        post("noroom-\(stuck.seat.id)-\(Int((stuck.next?.at ?? .distantFuture).timeIntervalSince1970))",
             title: String(localized: "No account has room"), body: text, switchTo: nil)
    }

    /// Yesterday in one line, each morning.
    func morningSummary(apiValue: Double, replies: Int, switches: Int, billed: [String]) {
        var body = String(localized: "\(dollars(apiValue)) API value in \(replies.formatted()) replies, \(switches) switches.")
        body += " " + (billed.isEmpty
            ? String(localized: "No extra usage billed.")
            : String(localized: "Extra usage billed: \(billed.joined(separator: ", ")).")
        )
        post("summary-\(Int(Date.now.timeIntervalSince1970 / 86_400))", title: String(localized: "Yesterday in Claude Code"), body: body, switchTo: nil)
    }

    private func post(_ id: String, title: String, body: String, switchTo account: Seat?) {
        guard told.insert(id).inserted else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let account {
            content.categoryIdentifier = Self.category
            content.userInfo = ["seat": account.id]
        }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["seat"] as? String else { return }
        let tapped = response.actionIdentifier
        await MainActor.run {
            let model = AppModel.shared
            guard let account = model.state.seat(id) else { return }
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
