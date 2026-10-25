import SwiftUI
import SwitcherCore

/// The first window a new person sees: what the app does, and the one or two
/// things to do before the first switch.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 104, height: 104)
                    .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
                Text("Claude Switcher")
                    .font(.system(size: 30, weight: .bold))
                Text("Every Claude account, one click away.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 36)
            .padding(.bottom, 28)

            VStack(alignment: .leading, spacing: 18) {
                feature("arrow.triangle.2.circlepath", .blue, "Switch in one click",
                        "Claude restarts signed in as the other account. No sign-out, no email code.")
                feature("bubble.left.and.bubble.right.fill", .purple, "Chats come along",
                        "Every Claude Code chat and project shows up in every account, and work a switch cuts off continues.")
                feature("gauge.with.dots.needle.67percent", .orange, "Every limit at a glance",
                        "The 5-hour and weekly limits of all your accounts, live, and which one has the most room.")
                feature("square.and.arrow.down.on.square.fill", .green, "The same setup everywhere",
                        "Connectors, plugins, skills and Claude Code settings, copied from the account you choose.")
            }
            .padding(.horizontal, 44)

            Spacer(minLength: 24)

            VStack(spacing: 10) {
                HStack(spacing: 18) {
                    Toggle("Open at Login", isOn: Binding(get: { model.startsAtLogin }, set: { model.setStartsAtLogin($0) }))
                    Toggle("Notifications", isOn: Binding(get: { model.state.notify }, set: { on in Task { await model.setNotify(on) } }))
                }
                .toggleStyle(.checkbox)
                .font(.callout)
                HStack(spacing: 10) {
                    AddAccountButton()
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    Button {
                        model.finishOnboarding()
                        dismissWindow(id: "welcome")
                    } label: {
                        Text("Get Started").frame(minWidth: 120)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                }
                Text(model.activeAccount.map { "Signed in to Claude as \($0.displayName)." } ?? String(localized: "Sign in to Claude as usual; the account shows up here."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 26)
        }
        .frame(width: 560, height: 640)
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(.easeOut(duration: 0.35)) { appeared = true } }
    }

    private func feature(_ symbol: String, _ color: Color, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(color.gradient, in: .rect(cornerRadius: 10, style: .continuous))
                .symbolEffect(.bounce, value: appeared)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
