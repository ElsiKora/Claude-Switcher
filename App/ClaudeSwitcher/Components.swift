import SwiftUI
import SwitcherCore

/// Green while there is room, orange from 75 %, red at the switch threshold.
func usageColor(_ percent: Double, threshold: Double) -> Color {
    switch percent {
    case threshold...: .red
    case 75...: .orange
    default: .green
    }
}

/// A System Settings style icon: a white symbol on a small colored rounded square.
struct SettingsIcon: View {
    let systemName: String
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: .rect(cornerRadius: size * 0.24, style: .continuous))
    }
}

/// A round badge with the account's initials, tinted by the account id.
struct Avatar: View {
    let account: Account
    var size: CGFloat = 22

    private static let tints: [Color] = [.blue, .indigo, .teal, .purple, .pink, .orange, .mint, .cyan]

    var tint: Color {
        let sum = account.id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return Self.tints[sum % Self.tints.count]
    }

    var initials: String {
        let words = account.displayName.split(whereSeparator: { $0 == " " || $0 == "@" || $0 == "." })
        return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    var body: some View {
        Text(verbatim: initials.isEmpty ? "?" : initials)
            .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: .circle)
    }
}

/// A thin bar for one limit.
struct UsageBar: View {
    let percent: Double?
    let threshold: Double
    var height: CGFloat = 5
    /// The limit's own colors (see LimitStyle); green-to-red when not given.
    var colors: [Color]?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(colors.map { AnyShapeStyle(LinearGradient(colors: $0, startPoint: .leading, endPoint: .trailing)) }
                        ?? AnyShapeStyle(usageColor(percent ?? 0, threshold: threshold).gradient))
                    .frame(width: max(height, geo.size.width * min(max((percent ?? 0) / 100, 0), 1)))
                    .opacity(percent == nil ? 0 : 1)
            }
        }
        .frame(height: height)
    }
}

extension Date {
    /// "18:00" today, "Tue 18:00" later.
    var resetText: String {
        Calendar.current.isDateInToday(self)
            ? formatted(date: .omitted, time: .shortened)
            : formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

func percentText(_ value: Double?) -> String {
    value.map { "\(Int($0.rounded()))%" } ?? "–"
}

/// One line under an account name: both limits, or why there are none.
func usageSummary(_ account: Account, now: Date) -> String {
    if let problem = account.problem { return problem }
    guard let u = account.usage?.current(at: now) else { return String(localized: "Checking usage…") }
    return String(localized: "5-hour \(percentText(u.session)) · Weekly \(percentText(u.weekly))")
}
