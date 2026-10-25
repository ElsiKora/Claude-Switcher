import Charts
import SwiftUI
import SwitcherCore

/// Claude Code usage of every account: tokens, what it would cost at API
/// prices, by day, model, account and chat, from Claude Code's transcripts.
struct AnalyticsView: View {
    @Environment(AppModel.self) private var model
    @State private var range: Insights.Range = .week
    @State private var split: Split = .model
    @State private var metric: Metric = .cost

    enum Split: String, CaseIterable, Identifiable { case model = "Model", account = "Account"; var id: String { rawValue } }
    enum Metric: String, CaseIterable, Identifiable { case cost = "API Value", tokens = "Tokens"; var id: String { rawValue } }

    var body: some View {
        let insights = model.insights
        let report = insights.report(range, timeline: model.timeline)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(insights)
                tiles(report)
                chart(report)
                HStack(alignment: .top, spacing: 16) {
                    modelsCard(report)
                    accountsCard(report)
                }
                billedCard
                chatsCard(report)
                Text("\(Pricing.source). Counts every Claude Code reply in ~/.claude/projects, subagents included; replies with the same message id count once. The API value is what the same tokens would cost through the API, not what the subscription charges.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
        }
        .defaultScrollAnchor(.top)
        .navigationTitle("Analytics")
        .task { await insights.refresh(model) }
    }

    private func header(_ insights: Insights) -> some View {
        HStack(spacing: 12) {
            Picker("Range", selection: $range) {
                ForEach(Insights.Range.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            Spacer()
            if let progress = insights.progress {
                ProgressView(value: progress).frame(width: 120)
                Text("Reading transcripts \(Int(progress * 100))%")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            } else if let at = insights.updatedAt {
                Text("Updated \(at.formatted(date: .omitted, time: .shortened))").font(.callout).foregroundStyle(.secondary)
            }
            Button { Task { await insights.refresh(model) } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Read new transcripts")
        }
    }

    // MARK: - Tiles

    private func tiles(_ r: UsageReport) -> some View {
        let t = r.total
        let all = [
            Tile(title: "API value", value: dollars(t.cost), detail: String(localized: "What these tokens cost through the API"),
                 symbol: "dollarsign.circle.fill", color: .green),
            Tile(title: "Tokens", value: compact(t.tokens.total),
                 detail: String(localized: "\(compact(t.tokens.input + t.tokens.write5m + t.tokens.write1h)) in · \(compact(t.tokens.output)) out · \(compact(t.tokens.cacheRead)) cached"),
                 symbol: "number.circle.fill", color: .blue),
            Tile(title: "Replies", value: t.tokens.messages.formatted(), detail: String(localized: "Claude Code replies, subagents included"),
                 symbol: "bubble.left.and.text.bubble.right.fill", color: .purple),
            Tile(title: "Cache hits", value: t.cacheHitRate.formatted(.percent.precision(.fractionLength(0))),
                 detail: String(localized: "Of input read from the cache"), symbol: "bolt.circle.fill", color: .orange),
        ]
        // One row of four when they fit, else two rows of two; never three and one.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                ForEach(all.indices, id: \.self) { all[$0].frame(minWidth: 210) }
            }
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow { all[0]; all[1] }
                GridRow { all[2]; all[3] }
            }
        }
    }

    // MARK: - Chart

    private func chart(_ r: UsageReport) -> some View {
        let days = split == .model ? r.daysByModel : r.daysByAccount
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("By Day").font(.headline).fixedSize()
                Spacer()
                Picker("Show", selection: $metric) { ForEach(Metric.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                Picker("Split", selection: $split) { ForEach(Split.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 180)
            }
            if days.isEmpty {
                ContentUnavailableView("No usage in this range", systemImage: "chart.bar")
                    .frame(height: 220)
            } else {
                Chart(days) { day in
                    BarMark(
                        x: .value("Day", day.day, unit: .day),
                        y: .value(metric.rawValue, metric == .cost ? day.total.cost : Double(day.total.tokens.total)))
                    .foregroundStyle(by: .value(split.rawValue, label(day.key)))
                    .cornerRadius(3)
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let v = value.as(Double.self) { Text(metric == .cost ? dollars(v) : compact(Int(v))) }
                        }
                    }
                }
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 240)
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
    }

    private func label(_ key: String) -> String {
        split == .model ? key : model.state.account(key)?.displayName ?? String(localized: "Other")
    }

    // MARK: - Breakdowns

    private func modelsCard(_ r: UsageReport) -> some View {
        let rows = r.byModel.sorted { $0.value.cost > $1.value.cost }
        let top = rows.first?.value.cost ?? 0
        return Card(title: "By Model") {
            ForEach(rows, id: \.key) { name, total in
                BreakdownRow(title: name, subtitle: String(localized: "\(compact(total.tokens.total)) tokens · \(total.tokens.messages.formatted()) replies"),
                             value: dollars(total.cost), share: top > 0 ? total.cost / top : 0)
            }
        }
    }

    private func accountsCard(_ r: UsageReport) -> some View {
        let rows = r.byAccount.sorted { $0.value.cost > $1.value.cost }
        let top = rows.first?.value.cost ?? 0
        return Card(title: "By Account") {
            ForEach(rows, id: \.key) { id, total in
                let account = model.state.account(id)
                HStack(spacing: 10) {
                    if let account { AccountRings(account: account, size: 26) } else {
                        Image(systemName: "person.crop.circle.badge.questionmark").font(.system(size: 20)).foregroundStyle(.secondary).frame(width: 26)
                    }
                    BreakdownRow(title: account?.displayName ?? String(localized: "Other"), subtitle: billedLine(account, total),
                                 value: dollars(total.cost), share: top > 0 ? total.cost / top : 0)
                }
            }
        }
    }

    /// The tokens, and what claude.ai billed beyond the plan this month.
    private func billedLine(_ account: Account?, _ total: UsageTotal) -> String {
        var line = String(localized: "\(compact(total.tokens.total)) tokens")
        if let extra = account?.usage?.extra, extra.enabled, let used = extra.used {
            line += " · " + String(localized: "billed beyond plan \(money(used, extra.currency)) this month")
        }
        return line
    }

    /// What claude.ai billed beyond each plan this month, in the account's currency.
    @ViewBuilder private var billedCard: some View {
        let rows = model.sortedAccounts.compactMap { a -> (Account, ExtraUsage)? in
            guard let extra = a.usage?.extra else { return nil }
            return (a, extra)
        }
        if !rows.isEmpty {
            Card(title: "Billed Beyond the Plan (this month)") {
                ForEach(rows, id: \.0.id) { account, extra in
                    HStack(spacing: 10) {
                        AccountRings(account: account, size: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.displayName)
                            Text(extra.enabled
                                 ? (extra.limit.map { String(localized: "Extra usage on, limit \(money($0, extra.currency))") } ?? String(localized: "Extra usage on, no monthly limit"))
                                 : String(localized: "Extra usage off"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(extra.enabled ? money(extra.used ?? 0, extra.currency) : "–")
                            .monospacedDigit().fontWeight(.semibold)
                            .foregroundStyle((extra.used ?? 0) > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    }
                }
                Text("Charged by Anthropic at API prices once a plan\u{2019}s limits run out, as claude.ai reports it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func chatsCard(_ r: UsageReport) -> some View {
        let titles = Dictionary(model.insights.chats.map { ($0.conversation, $0.title) }, uniquingKeysWith: { a, _ in a })
        let rows = r.byConversation.sorted { $0.value.cost > $1.value.cost }.prefix(8)
        let top = rows.first?.value.cost ?? 0
        return Card(title: "Costliest Chats (all time)") {
            ForEach(Array(rows), id: \.key) { id, total in
                BreakdownRow(title: titles[id] ?? String(localized: "Terminal or deleted chat"),
                             subtitle: String(localized: "\(compact(total.tokens.total)) tokens · \(total.tokens.messages.formatted()) replies"),
                             value: dollars(total.cost), share: top > 0 ? total.cost / top : 0)
            }
        }
    }
}

// MARK: - Pieces

private struct Tile: View {
    let title: LocalizedStringKey
    let value: String
    let detail: String
    let symbol: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label { Text(title).foregroundStyle(.secondary) } icon: { Image(systemName: symbol).foregroundStyle(color) }
                .font(.callout)
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 16, style: .continuous))
    }
}

private struct Card<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
    }
}

private struct BreakdownRow: View {
    let title: String
    let subtitle: String
    let value: String
    let share: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).lineLimit(1)
                Spacer()
                Text(value).monospacedDigit().fontWeight(.medium)
            }
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            GeometryReader { geo in
                Capsule().fill(.tint.opacity(0.7)).frame(width: max(3, geo.size.width * share))
            }
            .frame(height: 3)
        }
    }
}

func dollars(_ v: Double) -> String {
    v.formatted(.currency(code: "USD").precision(.fractionLength(v >= 100 ? 0 : 2)))
}

func money(_ v: Double, _ currency: String?) -> String {
    v.formatted(.currency(code: currency ?? "USD"))
}

func compact(_ n: Int) -> String {
    n.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
}
