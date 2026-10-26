import SwiftUI
import SwitcherCore

enum SidebarItem: Hashable {
    case account(String)
    case analytics
    case chats
    case activity
    case settings
}

/// The main window, laid out like System Settings: accounts in the sidebar,
/// a grouped form on the right.
struct MainWindow: View {
    /// The scene id. "main" until 0.2.1; renamed so a window size left over
    /// from then is not restored.
    static let id = "accounts"

    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.selection }, set: { model.selection = $0 })) {
                Section("Accounts") {
                    ForEach(model.sortedAccounts) { account in
                        AccountRow(account: account)
                            .tag(SidebarItem.account(account.id))
                            .contextMenu {
                                Button("Use as Reference Account") { model.setReference(account.id) }
                                    .disabled(model.referenceAccount?.id == account.id)
                            }
                    }
                }
                Section("Claude Code") {
                    Label {
                        Text("Analytics")
                    } icon: {
                        SettingsIcon(systemName: "chart.bar.xaxis", color: .teal)
                    }
                    .tag(SidebarItem.analytics)
                    Label {
                        Text("Chats")
                    } icon: {
                        SettingsIcon(systemName: "bubble.left.and.bubble.right.fill", color: .purple)
                    }
                    .tag(SidebarItem.chats)
                }
                Section {
                    Label {
                        Text("Activity")
                    } icon: {
                        SettingsIcon(systemName: "clock.arrow.circlepath", color: .gray)
                    }
                    .tag(SidebarItem.activity)
                    Label {
                        Text("Settings")
                    } icon: {
                        SettingsIcon(systemName: "gearshape.fill", color: .gray)
                    }
                    .tag(SidebarItem.settings)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    HoldChatsToggle()
                    AddAccountButton()
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            switch model.selection ?? defaultSelection {
            case let .account(id):
                if let account = model.state.account(id) {
                    AccountDetail(account: account)
                } else {
                    EmptyDetail()
                }
            case .analytics:
                AnalyticsView()
            case .chats:
                ChatsView()
            case .activity:
                ActivityView()
            case .settings:
                SettingsView()
            case nil:
                EmptyDetail()
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .sheet(item: Binding(get: { model.claudeAIPage }, set: { if $0 == nil { model.closeClaudeAIPage() } })) { page in
            ClaudeAIPageSheet(page: page)
        }
        .task {
            // Before the refresh: its first keychain read can wait on the user.
            if model.selection == nil { model.selection = Demo.initialSelection ?? defaultSelection }
            await model.refresh()
        }
    }
}

extension MainWindow {
    /// The signed-in account, else the first one; nil only without accounts.
    var defaultSelection: SidebarItem? {
        (model.active ?? model.accounts.first?.id).map(SidebarItem.account)
    }
}

struct AccountRow: View {
    @Environment(AppModel.self) private var model
    let account: Account

    var body: some View {
        HStack(spacing: 8) {
            AccountRings(account: account, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.displayName)
                    .lineLimit(1)
                Text(account.id == model.active ? String(localized: "Active") : usageSummary(account, now: model.now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if account.problem != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .imageScale(.small)
            } else if account.id == model.active {
                Circle().fill(.green).frame(width: 7, height: 7)
            }
        }
        .padding(.vertical, 2)
    }
}

struct EmptyDetail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("No Accounts Yet", systemImage: "person.crop.circle.badge.plus")
        } description: {
            Text("Sign in to Claude as usual. The account shows up here within a minute; then add the next one.")
        } actions: {
            AddAccountButton()
        }
    }
}

struct ActivityView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            if model.activity.isEmpty {
                Text("Switches, new sign-ins and imported chats show up here.")
                    .foregroundStyle(.secondary)
            } else {
                Section {
                    ForEach(model.activity) { item in
                        LabeledContent {
                            Text(item.date.resetText)
                                .monospacedDigit()
                        } label: {
                            Label {
                                Text(item.text)
                            } icon: {
                                Image(systemName: item.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                    .foregroundStyle(item.isError ? .orange : .green)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Activity")
    }
}
