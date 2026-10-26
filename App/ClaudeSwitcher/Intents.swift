import AppIntents
import SwitcherCore

/// A saved account, for Shortcuts, Spotlight and Siri.
struct AccountEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Claude Account"
    static let defaultQuery = AccountQuery()

    let id: String
    let name: String
    let detail: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(detail)", image: .init(systemName: "person.crop.circle"))
    }

    @MainActor
    init(_ account: Account, now: Date) {
        id = account.id
        name = account.displayName
        let u = account.usage?.current(at: now)
        detail = [account.plan, "5-hour \(percentText(u?.session)) · Week \(percentText(u?.weekly))"]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct AccountQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [AccountEntity] {
        let model = AppModel.shared
        return model.accounts.filter { identifiers.contains($0.id) }.map { AccountEntity($0, now: model.now) }
    }

    @MainActor
    func suggestedEntities() async throws -> [AccountEntity] {
        let model = AppModel.shared
        return model.sortedAccounts.map { AccountEntity($0, now: model.now) }
    }
}

struct SwitchAccountIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch Claude Account"
    static let description = IntentDescription("Restarts Claude signed in as another account. Chats at work continue afterwards.")

    @Parameter(title: "Account")
    var account: AccountEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Switch Claude to \(\.$account)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        guard let target = model.state.account(account.id) else { throw SwitchError.unknownAccount }
        if target.id == model.active { return .result(dialog: "Claude is already signed in as \(target.displayName).") }
        await model.switchTo(target)
        if let error = model.error { return .result(dialog: "\(error)") }
        return .result(dialog: "Claude is signed in as \(target.displayName).")
    }
}

struct SwitchToBestAccountIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch to the Account with the Most Room"
    static let description = IntentDescription("Restarts Claude signed in as the account with the most of its limits left.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        guard let best = model.roomiest, best.id != model.activeSeatID else {
            return .result(dialog: "The account Claude is signed in to already has the most room.")
        }
        await model.switchTo(best)
        if let error = model.error { return .result(dialog: "\(error)") }
        return .result(dialog: "Claude is signed in as \(best.displayName).")
    }
}

struct ClaudeUsageIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Claude Usage"
    static let description = IntentDescription("Tells how much of the 5-hour and weekly limits each account has used.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let model = AppModel.shared
        let lines = model.sortedAccounts.map { a in
            let u = a.usage?.current(at: model.now)
            let mark = a.id == model.active ? " (signed in)" : ""
            return "\(a.displayName)\(mark): 5-hour \(percentText(u?.session)), week \(percentText(u?.weekly))"
        }
        let text = lines.isEmpty ? "No accounts yet." : lines.joined(separator: "\n")
        return .result(value: text, dialog: "\(text)")
    }
}

struct SwitcherShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SwitchAccountIntent(),
            phrases: ["Switch Claude account with \(.applicationName)", "Switch \(.applicationName) to \(\.$account)"],
            shortTitle: "Switch Account", systemImageName: "arrow.triangle.2.circlepath")
        AppShortcut(
            intent: SwitchToBestAccountIntent(),
            phrases: ["Switch to the account with the most room in \(.applicationName)"],
            shortTitle: "Most Room Left", systemImageName: "sparkles")
        AppShortcut(
            intent: ClaudeUsageIntent(),
            phrases: ["Show Claude usage in \(.applicationName)"],
            shortTitle: "Claude Usage", systemImageName: "gauge.with.dots.needle.33percent")
    }
}
