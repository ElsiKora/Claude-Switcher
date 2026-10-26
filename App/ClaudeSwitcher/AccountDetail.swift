import SwiftUI
import SwitcherCore

/// One account: who it is, how much of its limits is used, what it lacks
/// compared with the reference account, and the switch.
struct AccountDetail: View {
    @Environment(AppModel.self) private var model
    let account: Account
    @State private var confirmingRemove = false

    private var isActive: Bool { account.id == model.active }
    private var usage: Usage? { account.usage?.current(at: model.now) }

    var body: some View {
        Form {
            Section {
                header
            }
            Notices()

            if (account.orgs?.count ?? 0) > 1 {
                WorkspacesSection(account: account)
            }

            Section {
                let forecast = model.forecast(account)
                limitRow("5-hour limit", icon: "clock.fill", color: .blue, percent: usage?.session, reset: usage?.sessionReset,
                         runsOut: forecast?.session,
                         colors: LimitStyle.session(usage?.session ?? 0, threshold: model.state.threshold))
                limitRow("Weekly limit", icon: "calendar", color: .purple, percent: usage?.weekly, reset: usage?.weeklyReset,
                         runsOut: forecast?.weekly,
                         colors: LimitStyle.week(usage?.weekly ?? 0, threshold: model.state.threshold))
            } header: {
                if let org = account.orgs?.first(where: { $0.id == account.org }), (account.orgs?.count ?? 0) > 1 {
                    Text("Usage in \(org.label)")
                } else {
                    Text("Usage")
                }
            } footer: {
                if let checked = account.usage?.checkedAt {
                    Text("Checked \(checked.formatted(.relative(presentation: .named))).")
                }
            }

            ForEach(model.state.seats.filter { $0.account.id == account.id }) { seat in
                SetupSection(seat: seat)
            }

            if !isActive {
                Section {
                    Button("Remove Account…", role: .destructive) { confirmingRemove = true }
                } footer: {
                    Text("Removes the saved sign-in from this Mac. The account itself and its chats stay.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(account.displayName)
        .confirmationDialog("Remove \(account.displayName)?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive) { model.remove(account) }
        } message: {
            Text("To use it again, add it with Add Account and sign in once more.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            AccountRings(account: account, size: 84)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(account.displayName).font(.title2.weight(.semibold))
                    if !account.plan.isEmpty {
                        Text(account.plan)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: .capsule)
                    }
                }
                if !account.email.isEmpty, account.email != account.displayName {
                    Text(account.email).foregroundStyle(.secondary)
                }
                if let problem = account.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
            Spacer()
            if isActive {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout.weight(.medium))
            } else {
                SwitchButton(account: account)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(.vertical, 6)
    }

    private func limitRow(_ title: LocalizedStringKey, icon: String, color: Color, percent: Double?, reset: Date?, runsOut: Date?,
                          colors: [Color]) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                UsageBar(percent: percent, threshold: model.state.threshold, height: 6, colors: colors)
                    .frame(width: 140)
                Text(percentText(percent))
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
            }
        } label: {
            Label {
                Text(title)
                switch (reset, runsOut) {
                case let (reset?, out?): Text("Runs out about \(out.resetText) at this pace · resets \(reset.resetText)")
                case let (nil, out?): Text("Runs out about \(out.resetText) at this pace")
                case let (reset?, nil): Text("Resets \(reset.resetText)")
                case (nil, nil): EmptyView()
                }
            } icon: {
                SettingsIcon(systemName: icon, color: color)
            }
        }
    }
}

/// The account's claude.ai setup compared with the reference account, read
/// live from claude.ai, and the copy that brings it up to date.
struct SetupSection: View {
    @Environment(AppModel.self) private var model
    let seat: Seat
    @State private var confirming = false
    @State private var switchingToConnect = false

    private var account: Account { seat.account }

    var body: some View {
        if let reference = model.referenceSeat, model.state.seats.count > 1 {
            Section {
                LabeledContent {
                    if reference.id != seat.id {
                        Button("Use as Reference") { model.setReference(seat.id) }
                    }
                } label: {
                    Label {
                        if reference.id == seat.id {
                            Text("Reference account")
                            Text("The other accounts and workspaces are compared with this one.")
                        } else {
                            Text("Compared with \(reference.displayName)")
                            Text("Connectors, plugins and skills live on claude.ai in each account and workspace.")
                        }
                    } icon: {
                        SettingsIcon(systemName: "star.fill", color: .yellow)
                    }
                }
                if let error = model.cloudErrors[seat.id] {
                    Label("Could not read claude.ai: \(error)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if let mine = model.cloudSetups[seat.id] {
                    let gaps = model.setupGaps(seat)
                    connectorsRow(mine, gaps)
                    pluginsRow(mine, gaps)
                    skillsRow(mine, gaps)
                    if let gaps, reference.id != seat.id { copyRow(reference, gaps) }
                } else if model.cloudErrors[seat.id] == nil {
                    LabeledContent("Reading claude.ai\u{2026}") { ProgressView().controlSize(.small) }
                }
                LabeledContent {
                    Text(model.state.mirrorSettings ? "Kept in sync" : "Off")
                        .foregroundStyle(.secondary)
                } label: {
                    Label {
                        Text("Claude Code settings")
                        Text("Session presets, folder permissions, sidebar sections")
                    } icon: {
                        SettingsIcon(systemName: "terminal.fill", color: .gray)
                    }
                }
            } header: {
                if let org = seat.org { Text("Setup in \(org.label)") } else { Text("Setup") }
            } footer: {
                if (model.cloudSetups[seat.id]?.connectors.contains { !$0.connected } ?? false) {
                    Text(seat.id == model.activeSeatID
                         ? String(localized: "Connect opens the Connectors page in Claude. Sign in to each connector there with its Connect button.")
                         : String(localized: "Connectors are signed in to in Claude, in the account and workspace it has open. Connect switches Claude to \(seat.displayName) first."))
                }
            }
            .task(id: seat.id) { await model.refreshCloudSetups() }
            .confirmationDialog("Switch Claude to \(seat.displayName)?", isPresented: $switchingToConnect) {
                Button("Switch and Open Connectors") { Task { await model.openConnectors(in: seat) } }
            } message: {
                Text("Connectors are signed in to in Claude, in the account and workspace it has open. Claude restarts in \(seat.displayName), and its Connectors page opens. Chats it cuts off continue.")
            }
            .confirmationDialog("Set up \(seat.displayName) like \(reference.displayName)?", isPresented: $confirming) {
                Button("Copy Setup") { Task { await model.copySetup(to: seat) } }
            } message: {
                Text("Adds \(reference.displayName)\u{2019}s missing connectors to \(seat.displayName) on claude.ai with their tool switches, approvals and permissions, and turns on the same plugins and skills, the way claude.ai\u{2019}s Settings do. Nothing is removed or turned off. Afterwards the switcher reads claude.ai again and shows what is there. You then sign in to each new connector.")
            }
        }
    }

    /// One kind of setup: icon, title and count on the left, its state and
    /// action on the right, and what it concerns in a line of names below.
    @ViewBuilder
    private func setupRow(_ title: LocalizedStringKey, subtitle: String, icon: String, color: Color,
                          state: String?, attention: Bool, action: LocalizedStringKey?, path: String,
                          perform: (() -> Void)? = nil,
                          notes: [(LocalizedStringKey, [String])]) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                if let state {
                    Text(state).foregroundStyle(attention ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                } else {
                    Image(systemName: "checkmark").foregroundStyle(.secondary)
                }
                if let action, let perform {
                    Button(action, action: perform)
                } else if let action, seat.id == model.activeSeatID {
                    Button(action) { model.openInClaude(path) }
                }
            }
        } label: {
            Label {
                Text(title)
                Text(subtitle)
                ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                    if !note.1.isEmpty {
                        Text("\(Text(note.0)): \(note.1.joined(separator: ", "))")
                    }
                }
            } icon: {
                SettingsIcon(systemName: icon, color: color)
            }
        }
    }

    @ViewBuilder
    private func connectorsRow(_ mine: CloudSetup, _ gaps: CloudSetup.Gaps?) -> some View {
        let missing = gaps?.missingConnectors ?? []
        let signIn = gaps?.signIn ?? mine.connectors.filter { !$0.connected }
        setupRow("Connectors", subtitle: String(localized: "\(mine.connectors.count - signIn.count) of \(mine.connectors.count) signed in"),
                 icon: "point.3.connected.trianglepath.dotted", color: .blue,
                 state: missing.isEmpty && signIn.isEmpty ? nil : summary(missing: missing.count, signIn: signIn.count),
                 attention: !missing.isEmpty || !signIn.isEmpty,
                 action: signIn.isEmpty ? nil : "Connect\u{2026}", path: "/settings/connectors",
                 perform: model.hasSignIn(account)
                     ? { if seat.id == model.activeSeatID { Task { await model.openConnectors(in: seat) } } else { switchingToConnect = true } }
                     : nil,
                 notes: [("Missing", missing.map(\.name)), ("Needs sign-in", signIn.map(\.name))])
    }

    private func summary(missing: Int, signIn: Int) -> String {
        let sign = signIn == 1 ? String(localized: "1 needs sign-in") : String(localized: "\(signIn) need sign-in")
        switch (missing, signIn) {
        case (0, _): return sign
        case (let m, 0): return String(localized: "\(m) missing")
        case let (m, _): return String(localized: "\(m) missing") + ", " + sign
        }
    }

    @ViewBuilder
    private func pluginsRow(_ mine: CloudSetup, _ gaps: CloudSetup.Gaps?) -> some View {
        let missing = gaps?.plugins ?? []
        setupRow("Plugins", subtitle: String(localized: "\(mine.plugins.count) on"),
                 icon: "puzzlepiece.extension.fill", color: .green,
                 state: missing.isEmpty ? nil : String(localized: "\(missing.count) missing"), attention: !missing.isEmpty,
                 action: nil, path: "/customize/plugins", notes: [("Missing", missing.map(\.name))])
    }

    @ViewBuilder
    private func skillsRow(_ mine: CloudSetup, _ gaps: CloudSetup.Gaps?) -> some View {
        let missing = gaps?.skills ?? []
        let custom = gaps?.customSkills ?? []
        let unavailable = gaps?.unavailableSkills ?? []
        setupRow("Skills", subtitle: String(localized: "\(mine.skills.count) on"),
                 icon: "sparkles", color: .orange,
                 state: missing.count + custom.count == 0 ? nil : String(localized: "\(missing.count + custom.count) missing"),
                 attention: missing.count + custom.count > 0,
                 action: custom.isEmpty ? nil : "Upload\u{2026}", path: "/customize/skills",
                 notes: [("Missing", missing.map(\.name)), ("Upload by hand", custom.map(\.name)),
                         ("Not offered to this account", unavailable.map(\.name))])
    }

    private func copyRow(_ reference: Seat, _ gaps: CloudSetup.Gaps) -> some View {
        LabeledContent {
            if model.copyingSetupTo == seat.id {
                ProgressView().controlSize(.small)
            } else {
                Button("Copy Setup\u{2026}") { confirming = true }
                    .disabled(model.copyingSetupTo != nil || gaps.copyable == 0 || !model.hasSignIn(account) || !model.hasSignIn(reference.account))
            }
        } label: {
            Label {
                Text("Set up like \(reference.displayName)")
                if let verified = model.setupVerified[seat.id] {
                    Text(verified)
                } else if let result = model.setupCopies[seat.id] {
                    Text(copySummary(result))
                } else if gaps.copyable == 0 {
                    Text("Nothing left to copy.")
                } else {
                    Text("Adds missing connectors with their tool settings and turns on the same plugins and skills.")
                }
            } icon: {
                SettingsIcon(systemName: "square.and.arrow.down.on.square.fill", color: .blue)
            }
        }
    }

    private func copySummary(_ r: SetupCopy.Result) -> String {
        var text = String(localized: "Copied \(r.connectors.count) connectors, \(r.plugins.count) plugins, \(r.skills.count) skills and \(r.toolSettings) tool settings.")
        if !r.failed.isEmpty { text += " " + String(localized: "Not done: \(r.failed.joined(separator: ", ")).") }
        if !r.needOAuthClient.isEmpty { text += " " + String(localized: "Enter the OAuth client again for \(r.needOAuthClient.joined(separator: ", ")).") }
        return text
    }
}

/// Switches to an account. Chats at work are continued after the restart.
struct SwitchButton: View {
    @Environment(AppModel.self) private var model
    let account: Account
    var title: LocalizedStringKey = "Switch to This Account"

    var body: some View {
        Button(title) { Task { await model.switchTo(account) } }
        .disabled(model.isBusy || !model.hasSignIn(account))
        .help(model.hasSignIn(account) ? "Restarts Claude signed in as \(account.displayName)" : "Add the account again to sign in once more")
    }
}

/// The workspaces of an account that has several (its own plan and its
/// teams): each one's limits, the switch between them, and whether
/// automatic switching may use it.
struct WorkspacesSection: View {
    @Environment(AppModel.self) private var model
    let account: Account

    var body: some View {
        Section {
            ForEach(model.state.seats.filter { $0.account.id == account.id }) { seat in
                if let org = seat.org {
                    row(seat, org)
                    Toggle(isOn: Binding(get: { !seat.excluded }, set: { model.setExcluded(seat, !$0) })) {
                        Text("Use for automatic switching")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 34)
                }
            }
        } header: {
            Text("Workspaces")
        } footer: {
            Text("Each workspace has limits of its own, and the switcher counts all of them; the checkmark marks the one open in Claude. Switch workspaces in Claude itself, and the switcher follows. Automatic switching may also move between them when one runs low, unless you leave a workspace out.")
        }
    }

    private func row(_ seat: Seat, _ org: Org) -> some View {
        let u = seat.usage?.current(at: model.now)
        let isOpen = seat.orgID == account.org
        let signedIn = account.id == model.active
        return LabeledContent {
            HStack(spacing: 8) {
                if isOpen {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(signedIn ? .green : .secondary)
                        .help(signedIn ? "Claude has this workspace open" : "The workspace this account opens in")
                }
                AccountRings(account: seat.inWorkspace, size: 28)
            }
        } label: {
            Label {
                Text(org.kind == .personal ? String(localized: "Personal") : org.name)
                Text(seat.problem ?? String(localized: "5-hour \(percentText(u?.session)) · Week \(percentText(u?.weekly))\(org.kind == .personal ? "" : " · " + String(localized: "Team"))"))
            } icon: {
                SettingsIcon(systemName: org.kind == .personal ? "person.fill" : "person.3.fill", color: org.kind == .personal ? .blue : .indigo)
            }
        }
    }
}
