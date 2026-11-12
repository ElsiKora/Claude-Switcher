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

    var tint: Color { Self.tint(for: account.id) }

    /// The account's color, the same in its avatar and in charts.
    static func tint(for id: String) -> Color {
        let sum = id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return tints[sum % tints.count]
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

/// "↺ 2": the limit resets an account has left. Nothing when it has none.
struct ResetsBadge: View {
    let resets: LimitResets?
    let now: Date
    var size: CGFloat = 10

    var body: some View {
        if let resets, let first = resets.active(at: now).first {
            let left = resets.left(at: now)
            Label { Text(verbatim: "\(left)") } icon: { Image(systemName: "arrow.counterclockwise") }
                .labelStyle(.titleAndIcon)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.mint)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.mint.opacity(0.15), in: .capsule)
                .help(left == 1
                      ? String(localized: "1 limit reset left, to use by \(useByText(first.endsAt, now: now)). Use it in Claude once this account reaches a limit it refills.")
                      : String(localized: "\(left) limit resets left, the first to use by \(useByText(first.endsAt, now: now)). Use them in Claude once this account reaches a limit they refill."))
        }
    }
}

/// What a limit reset refills, in a few words.
func resetKind(_ grant: LimitResets.Grant) -> String {
    if grant.givesBackWeekly { return String(localized: "Fable reset") }
    return switch (grant.refillsFiveHour, grant.refillsWeekly) {
    case (true, true): String(localized: "5-hour and weekly reset")
    case (true, false): String(localized: "5-hour reset")
    case (false, true): String(localized: "Weekly reset")
    case (false, false): String(localized: "Limit reset")
    }
}

/// "Fri 18:00" within the week, "14 Nov, 18:00" further out.
func useByText(_ date: Date, now: Date) -> String {
    date.timeIntervalSince(now) < 6 * 86_400 ? date.resetText : date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
}

/// All limit resets of an account's workspaces together, for counting.
func accountResets(_ account: Account, in state: SwitcherState) -> LimitResets? {
    let all = state.seats.filter { $0.account.id == account.id }.compactMap { $0.usage?.resets }
    return all.isEmpty ? nil : LimitResets(eligible: all.contains(where: \.eligible), grants: all.flatMap(\.grants))
}
