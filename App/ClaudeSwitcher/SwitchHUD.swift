import AppKit
import SwiftUI
import SwitcherCore

/// How the last restart ended, for the HUD.
struct Outcome: Equatable {
    var succeeded: Bool
    var title: String
    var detail: String
}

/// A glass panel in the middle of the screen while Claude restarts: Claude's
/// own window is gone then, so this is where the switch shows its steps and
/// how it ended. It fades in and out; nothing in it moves or resizes.
@MainActor
final class SwitchHUD {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ model: AppModel) {
        hideTask?.cancel()
        let panel = panel ?? makePanel(model)
        self.panel = panel
        if let screen = NSScreen.main {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2 + screen.frame.height * 0.12))
        }
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
    }

    /// Keeps the outcome on screen for a moment, then fades away.
    func finish(after seconds: Double = 2.6) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let panel = self?.panel else { return }
            await NSAnimationContext.runAnimationGroup { $0.duration = 0.35; panel.animator().alphaValue = 0 }
            panel.orderOut(nil)
        }
    }

    private func makePanel(_ model: AppModel) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 250),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        let host = NSHostingView(rootView: SwitchHUDView().environment(model))
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = host
        return panel
    }
}

struct SwitchHUDView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            icon.frame(height: 46)
            VStack(spacing: 4) {
                Text(title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineLimit(2)
                    .frame(height: 32, alignment: .top)
            }
            steps
        }
        .padding(22)
        .frame(width: 360, height: 250)
        .glassEffect(.regular, in: .rect(cornerRadius: 28, style: .continuous))
    }

    @ViewBuilder private var icon: some View {
        if let outcome = model.outcome, model.phase == nil {
            Image(systemName: outcome.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(outcome.succeeded ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
                .symbolEffect(.bounce, value: outcome)
        } else {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(.tint)
                .symbolEffect(.rotate, options: .repeating)
        }
    }

    private var title: String {
        if let outcome = model.outcome, model.phase == nil { return outcome.title }
        return switch model.phase {
        case let .switching(name): String(localized: "Switching to \(name)")
        case .adding: String(localized: "Getting Claude ready")
        case .importing: String(localized: "Bringing chats along")
        case .continuing: String(localized: "Continuing chats")
        case .waitingForSignIn: String(localized: "Sign in to Claude")
        case nil: ""
        }
    }

    private var detail: String {
        if let outcome = model.outcome, model.phase == nil { return outcome.detail }
        return switch model.step {
        case .quit: String(localized: "Claude saves every chat first. Chats at work continue afterwards.")
        case .swap: String(localized: "Swapping the sign-in.")
        case .chats: String(localized: "Bringing chats, projects and settings along.")
        case .launch: String(localized: "Starting Claude.")
        case .signIn, nil: ""
        }
    }

    private var steps: some View {
        let all: [Phase.Step] = [.quit, .swap, .chats, .launch]
        let shown = model.phase?.steps.filter { all.contains($0) } ?? all
        let current = model.step.flatMap { shown.firstIndex(of: $0) } ?? (model.phase == nil ? shown.count : 0)
        return HStack(spacing: 6) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, step in
                HStack(spacing: 4) {
                    Group {
                        if index < current {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if index == current, model.phase != nil {
                            Image(systemName: "circle.dotted").foregroundStyle(.tint)
                                .symbolEffect(.pulse, options: .repeating)
                        } else {
                            Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                    }
                    .font(.system(size: 11))
                    Text(label(step)).font(.system(size: 11)).foregroundStyle(index <= current ? .primary : .secondary)
                }
                if index < shown.count - 1 {
                    Image(systemName: "chevron.compact.right").font(.system(size: 10)).foregroundStyle(.quaternary)
                }
            }
        }
    }

    private func label(_ step: Phase.Step) -> LocalizedStringKey {
        switch step {
        case .quit: "Close"
        case .swap: "Sign-in"
        case .chats: "Chats"
        case .launch: "Start"
        case .signIn: "Sign in"
        }
    }
}

/// The little confirmation a finished switch gives: a sound and, on a Force
/// Touch trackpad, a tap.
@MainActor
enum Feedback {
    static func success(sound: Bool) {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        if sound { NSSound(named: "Glass")?.play() }
    }

    static func failure(sound: Bool) {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        if sound { NSSound(named: "Basso")?.play() }
    }
}
