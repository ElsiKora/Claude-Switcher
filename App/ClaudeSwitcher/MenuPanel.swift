import SwiftUI
import SwitcherCore

/// The panel that opens from the menu bar: the signed-in account up top in
/// its rings, the others below, a click on one switches.
struct MenuPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Claude Switcher").font(.system(size: 13, weight: .semibold))
                Spacer()
                ClaudeStatus()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            PanelNotices()

            if let active = model.activeAccount {
                ActiveAccountCard(account: active)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }

            // Workspaces are switched in Claude itself; here each account shows the one it has open.
            let others = model.sortedAccounts.filter { $0.id != model.active }.compactMap { model.state.seat(of: $0) }
            if model.accounts.isEmpty {
                Text("Sign in to Claude as usual. The account shows up here within a minute.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            } else if !others.isEmpty {
                SectionTitle("Switch To")
                VStack(spacing: 0) {
                    ForEach(others) { seat in
                        PanelAccountRow(seat: seat)
                    }
                }
                .padding(.horizontal, 5)
            }

            Divider().padding(.horizontal, 14).padding(.vertical, 5)

            VStack(spacing: 0) {
                AddAccountButton(style: .menuRow)
                if model.state.autoSwitch || model.state.spendWeekly {
                    if model.isPaused, let until = model.state.pausedUntil {
                        MenuRow("Resume Automatic Switching (paused until \(until.resetText))", systemImage: "play.circle") {
                            model.resumeAutoSwitch()
                        }
                    } else {
                        MenuRow("Pause Automatic Switching for 2 Hours", systemImage: "pause.circle") {
                            model.pauseAutoSwitch()
                        }
                    }
                }
                MenuRow("Open Claude Switcher", systemImage: "macwindow") {
                    model.showMainWindow?()
                }
                Divider().padding(.horizontal, 9).padding(.vertical, 5)
                MenuRow("Quit Claude Switcher", systemImage: "power") { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 5)
            .padding(.bottom, 6)
        }
        .frame(width: 340)
        .task { await model.refresh() }
    }
}

/// The signed-in account: its rings large, both limits with their resets.
struct ActiveAccountCard: View {
    @Environment(AppModel.self) private var model
    let account: Account

    var body: some View {
        let usage = account.usage?.current(at: model.now)
        HStack(spacing: 14) {
            AccountRings(account: account, size: 64)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(account.displayName).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    if let org = model.activeSeat?.org {
                        WorkspaceBadge(org: org)
                    } else if !account.plan.isEmpty {
                        Text(account.plan)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: .capsule)
                    }
                }
                LimitLegend(title: "5-hour", percent: usage?.session, reset: usage?.sessionReset,
                            colors: LimitStyle.session(usage?.session ?? 0, threshold: model.state.threshold))
                LimitLegend(title: "Week", percent: usage?.weekly, reset: usage?.weeklyReset,
                            colors: LimitStyle.week(usage?.weekly ?? 0, threshold: model.state.threshold))
                if let first = model.forecast(account)?.first {
                    Text(first.weekly
                         ? String(localized: "At this pace the week runs out about \(first.date.resetText)")
                         : String(localized: "At this pace the 5-hour limit runs out about \(first.date.resetText)"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16, style: .continuous))
    }
}

struct SectionTitle: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 3)
    }
}

/// A menu-like row: icon, title, highlight on hover.
struct MenuRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(title)
                Spacer()
            }
            .font(.system(size: 13))
            .padding(.horizontal, 9)
            .frame(height: 24)
            .contentShape(.rect)
            .background(hovering && isEnabled ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct PanelAccountRow: View {
    @Environment(AppModel.self) private var model
    let seat: Seat
    @State private var hovering = false

    private var account: Account { seat.inWorkspace }
    private var usage: Usage? { seat.usage?.current(at: model.now) }
    private var canSwitch: Bool { !model.isBusy && model.hasSignIn(seat.account) }
    private var isBest: Bool { model.suggestion?.id == seat.id }

    var body: some View {
        Button {
            guard canSwitch else { return }
            Task { await model.switchTo(seat) }
        } label: {
            HStack(spacing: 10) {
                AccountRings(account: account, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(account.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        if let org = seat.org {
                            WorkspaceBadge(org: org)
                        } else if !account.plan.isEmpty {
                            Text(account.plan).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        if seat.excluded {
                            Image(systemName: "hand.raised.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                                .help("Left out of automatic switching")
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(account.problem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if isBest {
                    Label("Most room", systemImage: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.green)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.green.opacity(0.14), in: .capsule)
                        .symbolEffect(.pulse, options: .repeat(2), isActive: hovering)
                }
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.tint)
                    .opacity(hovering && canSwitch ? 1 : 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .contentShape(.rect)
            .background(hovering && canSwitch ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(seat.runsClaudeCode ? 1 : 0.55)
        .onHover { hovering = $0 }
        .help(canSwitch ? "Switch Claude to \(seat.displayName)" : "")
    }

    private var subtitle: String {
        if !seat.runsClaudeCode { return String(localized: "Free plan · not in rotation") }
        if let problem = seat.problem { return problem }
        if !model.hasSignIn(seat.account) { return String(localized: "Add it again to sign in") }
        return String(localized: "5-hour \(percentText(usage?.session)) · Week \(percentText(usage?.weekly))")
    }
}

struct ClaudeStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(model.claudeRunning ? Color.green : Color.secondary)
                .frame(width: 6, height: 6)
            Text(model.claudeRunning ? "Claude is running" : "Claude is closed")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

struct AddAccountButton: View {
    enum Style { case button, menuRow }

    @Environment(AppModel.self) private var model
    var style: Style = .button
    /// Which explanation is showing: one account, or several in a row.
    @State private var explaining: Bool?

    var body: some View {
        switch style {
        case .button:
            Menu {
                Button("Add Account\u{2026}") { explaining = false }
                if !model.state.holdChats {
                    Button("Add Several Accounts\u{2026}") { explaining = true }
                }
            } label: {
                Label("Add Account\u{2026}", systemImage: "plus")
            } primaryAction: {
                explaining = false
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!canAdd)
            .alert(title, isPresented: Binding(get: { explaining != nil }, set: { if !$0 { explaining = nil } })) {
                Button("Restart Claude") { start() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(message)
            }
        case .menuRow:
            // An alert would take focus from the menu bar panel and close it,
            // so the panel asks in place.
            if explaining != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Cancel") { explaining = nil }
                            .keyboardShortcut(.cancelAction)
                        Button("Restart Claude") { start() }
                            .keyboardShortcut(.defaultAction)
                    }
                    .controlSize(.small)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 10, style: .continuous))
                .padding(.vertical, 2)
            } else {
                MenuRow("Add Account\u{2026}", systemImage: "plus") { explaining = false }
                    .disabled(!canAdd)
                if !model.state.holdChats {
                    MenuRow("Add Several Accounts\u{2026}", systemImage: "person.2") { explaining = true }
                        .disabled(!canAdd)
                }
            }
        }
    }

    private var canAdd: Bool { !model.isBusy && model.phase != .waitingForSignIn }

    private var title: String {
        explaining == true ? String(localized: "Add Several Accounts") : String(localized: "Add Another Account")
    }

    private var message: String {
        explaining == true
            ? "\(Self.explanation) \(Self.several)\n\n\(Self.warning)"
            : "\(Self.explanation)\n\n\(Self.warning)"
    }

    private func start() {
        let several = explaining == true
        explaining = nil
        Task { several ? await model.addSeveralAccounts() : await model.addAccount() }
    }

    static let explanation = String(localized: "Your current sign-in is kept. Claude restarts on its sign-in screen; sign in there with the other account and Claude Switcher picks it up.")
    static let several = String(localized: "Chats a restart cuts off wait until you press Done after the last account, and then continue there.")
    static let warning = String(localized: "Never use Sign Out in Claude to change accounts: it ends the saved sign-in.")
}

/// Errors, a switch in progress, a switch waiting for Claude to be idle, and update news.
struct PanelNotices: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.state.holdChats {
                let held = model.state.heldChats.count
                NoticeRow(systemImage: "person.badge.plus", tint: .blue,
                          text: held == 0
                              ? String(localized: "Adding accounts. Chats wait until you press Done.")
                              : String(localized: "Adding accounts. \(held) chats wait to continue in the account you finish on.")) {
                    HStack(spacing: 10) {
                        Button("Add Another") { Task { await model.addAccount() } }
                        Button("Done") { Task { await model.setHoldChats(false) } }
                            .fontWeight(.semibold)
                    }
                    .disabled(model.isBusy || model.phase == .waitingForSignIn)
                }
            }
            if (model.state.autoSwitch || model.state.spendWeekly) && !model.quitPromptAllowed {
                NoticeRow(systemImage: "hand.raised.fill", tint: .orange,
                          text: String(localized: "Allow Claude Switcher in Accessibility so a switch can close Claude while chats work. Until then, a switch waits for Claude.")) {
                    Button("Allow…") { model.allowQuitPrompt() }
                }
            }
            if let error = model.error {
                NoticeRow(systemImage: "exclamationmark.triangle.fill", tint: .orange, text: error) {
                    Button("Dismiss") { model.dismissError() }
                }
            }
            if let phase = model.phase {
                PhaseRow(phase: phase, step: model.step)
            }
            if !model.cutOff.isEmpty {
                NoticeRow(systemImage: "arrow.uturn.forward.circle.fill", tint: .blue,
                          text: model.cutOffSummary) {
                    Menu("Open") {
                        ForEach(model.cutOff, id: \.id) { chat in
                            Button(chat.title.isEmpty ? chat.id : chat.title) { model.open(chat) }
                        }
                        Divider()
                        Button("Dismiss") { model.dismissCutOff() }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.link)
                    .fixedSize()
                }
            }
            if let note = model.autoNote {
                NoticeRow(systemImage: "arrow.triangle.2.circlepath", tint: .blue, text: note) { EmptyView() }
            }
            if let version = model.availableUpdate {
                NoticeRow(systemImage: "arrow.down.circle.fill", tint: .blue,
                          text: String(localized: "Version \(version) is available.")) {
                    Button("Download") { model.openReleasePage() }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, model.hasNotices ? 8 : 0)
    }
}

struct NoticeRow<Action: View>: View {
    let systemImage: String
    let tint: Color
    let text: String
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            action.buttonStyle(.link)
        }
        .font(.system(size: 12))
        .padding(8)
        .background(tint.opacity(0.1), in: .rect(cornerRadius: 8))
    }
}

/// A restart in progress, with the step it is on.
struct PhaseRow: View {
    @Environment(AppModel.self) private var model
    let phase: Phase
    let step: Phase.Step?

    var title: String {
        switch phase {
        case let .switching(name): String(localized: "Switching to \(name)")
        case .adding: String(localized: "Getting Claude ready for another account")
        case .waitingForSignIn: String(localized: "Sign in to Claude with the other account")
        case .importing: String(localized: "Bringing chats into the new account")
        case .continuing: String(localized: "Continuing the waiting chats")
        }
    }

    var stepText: String {
        switch step {
        case .quit: String(localized: "Closing Claude. It saves every chat first, which can take a minute.")
        case .swap: String(localized: "Swapping the sign-in…")
        case .chats: String(localized: "Bringing chats, projects and settings along…")
        case .launch: String(localized: "Starting Claude…")
        case .signIn: String(localized: "Waiting for the new sign-in…")
        case nil: ""
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(stepText).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if phase == .waitingForSignIn {
                Button("Cancel") { model.cancelAdding() }.buttonStyle(.link).font(.system(size: 12))
            }
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.1), in: .rect(cornerRadius: 8))
    }
}

/// The same notices inside a form.
struct Notices: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.hasNotices {
            Section {
                PanelNotices()
                    .padding(.horizontal, -14)
            }
        }
    }
}

/// Which workspace of an account a seat is: "Personal" or the team's name.
struct WorkspaceBadge: View {
    let org: Org

    var body: some View {
        Label(org.label, systemImage: org.kind == .personal ? "person.fill" : "person.3.fill")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: .capsule)
    }
}
