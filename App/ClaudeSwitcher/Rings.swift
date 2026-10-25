import SwiftUI
import SwitcherCore

/// The colors of the two limits, the same everywhere in the app: the
/// 5-hour limit in blue, the week in violet, both turning orange when
/// getting full and red at the switch threshold.
enum LimitStyle {
    static func session(_ percent: Double, threshold: Double) -> [Color] {
        warning(percent, threshold: threshold) ?? [Color(red: 0.25, green: 0.78, blue: 1.0), Color(red: 0.12, green: 0.45, blue: 1.0)]
    }

    static func week(_ percent: Double, threshold: Double) -> [Color] {
        warning(percent, threshold: threshold) ?? [Color(red: 0.86, green: 0.42, blue: 1.0), Color(red: 0.49, green: 0.30, blue: 1.0)]
    }

    private static func warning(_ percent: Double, threshold: Double) -> [Color]? {
        switch percent {
        case threshold...: [Color(red: 1.0, green: 0.42, blue: 0.36), Color(red: 0.92, green: 0.16, blue: 0.24)]
        case 75...: [Color(red: 1.0, green: 0.76, blue: 0.28), Color(red: 1.0, green: 0.52, blue: 0.16)]
        default: nil
        }
    }
}

/// One arc of a ring, filled with an angular gradient and a round cap.
struct RingArc: View {
    let fraction: Double
    let colors: [Color]
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(colors.last!.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(fraction, 1)))
                .stroke(
                    AngularGradient(colors: colors, center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * max(fraction, 0.01))),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(fraction > 0 ? 1 : 0)
        }
    }
}

/// Both limits of an account as two rings, like Activity rings: the 5-hour
/// limit outside, the week inside. Whatever goes in the middle is the content.
struct LimitRings<Center: View>: View {
    let usage: Usage?
    let threshold: Double
    var size: CGFloat = 44
    @ViewBuilder var center: Center

    var body: some View {
        let line = LimitRings<EmptyView>.lineWidth(size)
        let gap = line * 0.3
        let session = (usage?.session ?? 0) / 100
        let week = (usage?.weekly ?? 0) / 100
        ZStack {
            RingArc(fraction: session, colors: LimitStyle.session(usage?.session ?? 0, threshold: threshold), lineWidth: line)
            RingArc(fraction: week, colors: LimitStyle.week(usage?.weekly ?? 0, threshold: threshold), lineWidth: line)
                .padding(line + gap)
            center
        }
        .frame(width: size, height: size)
        .animation(.smooth(duration: 0.6), value: usage?.session)
        .animation(.smooth(duration: 0.6), value: usage?.weekly)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Usage"))
        .accessibilityValue(Text("5-hour \(percentText(usage?.session)), weekly \(percentText(usage?.weekly))"))
    }
}

extension LimitRings {
    static func lineWidth(_ size: CGFloat) -> CGFloat { max(2.5, size * 0.085) }
}

extension LimitRings where Center == EmptyView {
    init(usage: Usage?, threshold: Double, size: CGFloat = 44) {
        self.init(usage: usage, threshold: threshold, size: size) { EmptyView() }
    }
}

/// An avatar inside its account's rings.
struct AccountRings: View {
    @Environment(AppModel.self) private var model
    let account: Account
    var size: CGFloat = 44

    var body: some View {
        let line = LimitRings<EmptyView>.lineWidth(size)
        let inner = size - 4 * line * 1.3 - line * 0.5
        LimitRings(usage: account.usage?.current(at: model.now), threshold: model.state.threshold, size: size) {
            Avatar(account: account, size: max(8, inner))
        }
    }
}

/// A limit's percentage with a colored dot, for legends next to rings.
struct LimitLegend: View {
    let title: LocalizedStringKey
    let percent: Double?
    let reset: Date?
    let colors: [Color]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)).frame(width: 7, height: 7)
            Text(title).foregroundStyle(.secondary)
            Text(percentText(percent))
                .monospacedDigit()
                .contentTransition(.numericText())
                .fontWeight(.semibold)
            if let reset {
                Text("· \(reset.resetText)").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12))
    }
}
