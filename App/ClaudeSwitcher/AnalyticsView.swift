import Charts
import SwiftUI
import SwitcherCore

/// Claude Code usage of every account: tokens, what it would cost at API
/// prices, by day, model, account and chat, from Claude Code's transcripts,
/// and what claude.ai billed beyond each plan. Everything follows the range
/// and the account and model filters.
struct AnalyticsView: View {
    @Environment(AppModel.self) private var model
    @State private var range: Insights.Range = .week
    @State private var split: Split = .account
    @State private var metric: Metric = .cost
    @State private var accounts: Set<String>?
    @State private var models: Set<String>?
    @State private var group: Grouping = .dayAccount
    @State private var sortOrder = [KeyPathComparator(\BreakdownItem.day, order: .reverse)]

    enum Split: String, CaseIterable, Identifiable { case account = "Account", model = "Model"; var id: String { rawValue } }
    enum Metric: String, CaseIterable, Identifiable { case cost = "API Value", tokens = "Tokens"; var id: String { rawValue } }

    var body: some View {
        let insights = model.insights
        let report = insights.report(range, timeline: model.timeline, filter: UsageFilter(accounts: accounts, models: models))
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(insights, report)
                tiles(report)
                chart(report)
                breakdown(report)
                HStack(alignment: .top, spacing: 16) {
                    modelsCard(report)
                    accountsCard(report)
                }
                billedCard
                chatsCard(report)
                Text("\(Pricing.source). Counts every Claude Code reply in ~/.claude/projects, subagents included; replies with the same message id count once. The API value is what the same tokens would cost through the API, not what the subscription charges. Usage counts for the account Claude was signed in to at the time; before Claude Switcher\u{2019}s first switch, for the account whose chat list held the chat. Unattributed is usage no account can be named for: terminal sessions, deleted chats, and chats from before Claude Switcher that no account\u{2019}s list kept.")
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

    // MARK: - Header and filters

    private func header(_ insights: Insights, _ r: UsageReport) -> some View {
        HStack(spacing: 12) {
            Picker("Range", selection: $range) {
                ForEach(Insights.Range.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 340)
            filterMenu(title: accountsTitle(r), symbol: "person.2", all: r.accountsSeen, selection: $accounts, name: accountName)
            filterMenu(title: modelsTitle(r), symbol: "cpu", all: r.modelsSeen, selection: $models, name: { $0 })
            Spacer()
            if let progress = insights.progress {
                ProgressView(value: progress).frame(width: 100)
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

    private func filterMenu(title: String, symbol: String, all: Set<String>, selection: Binding<Set<String>?>,
                            name: @escaping (String) -> String) -> some View {
        Menu {
            Button("Show All") { selection.wrappedValue = nil }
            Divider()
            ForEach(all.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }, id: \.self) { key in
                Toggle(name(key), isOn: Binding(
                    get: { selection.wrappedValue?.contains(key) ?? true },
                    set: { on in
                        var set = selection.wrappedValue ?? all
                        if on { set.insert(key) } else { set.remove(key) }
                        selection.wrappedValue = set.isSuperset(of: all) ? nil : set
                    }))
            }
        } label: {
            Label(title, systemImage: symbol)
        }
        .fixedSize()
    }

    private func accountsTitle(_ r: UsageReport) -> String {
        guard let accounts else { return String(localized: "All Accounts") }
        return accounts.count == 1 ? accountName(accounts.first!) : String(localized: "\(accounts.count) Accounts")
    }

    private func modelsTitle(_ r: UsageReport) -> String {
        guard let models else { return String(localized: "All Models") }
        return models.count == 1 ? models.first! : String(localized: "\(models.count) Models")
    }

    /// The name usage is shown under: the account's, or what is known of it.
    private func accountName(_ id: String) -> String {
        if id.isEmpty { return String(localized: "Unattributed") }
        return model.state.account(id)?.displayName ?? String(localized: "Account not in Claude Switcher")
    }

    private func accountColor(_ id: String) -> Color {
        id.isEmpty || model.state.account(id) == nil ? .gray : Avatar.tint(for: id)
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
        let keys = Array(Set(days.map(\.key))).sorted { label($0).localizedStandardCompare(label($1)) == .orderedAscending }
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
                // Stacked segments stay square: rounding each one notches the stack.
                Chart(days) { day in
                    BarMark(
                        x: .value("Day", day.day, unit: .day),
                        y: .value(metric.rawValue, metric == .cost ? day.total.cost : Double(day.total.tokens.total)))
                    .foregroundStyle(by: .value(split.rawValue, label(day.key)))
                }
                .chartForegroundStyleScale(domain: keys.map(label), range: keys.map(color))
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: range == .all || range == .month ? 5 : 1)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: true)
                    }
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
        split == .model ? key : accountName(key)
    }

    private func color(_ key: String) -> Color {
        guard split == .account else {
            let palette: [Color] = [.green, .orange, .blue, .pink, .purple, .teal, .yellow, .red, .indigo, .mint]
            let sum = key.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
            return palette[sum % palette.count]
        }
        return accountColor(key)
    }

    // MARK: - Breakdown table

    enum Grouping: String, CaseIterable, Identifiable {
        case day = "Day", account = "Account", model = "Model", dayAccount = "Day & Account", accountModel = "Account & Model", chat = "Chat"
        var id: String { rawValue }
        var hasDay: Bool { self == .day || self == .dayAccount }
        var hasAccount: Bool { self == .account || self == .dayAccount || self == .accountModel }
        var hasModel: Bool { self == .model || self == .accountModel }
    }

    private func breakdown(_ r: UsageReport) -> some View {
        let items = breakdownItems(r).sorted(using: sortOrder)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Breakdown").font(.headline).fixedSize()
                Spacer()
                Picker("Group by", selection: $group) {
                    ForEach(Grouping.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .fixedSize()
            }
            Table(items, sortOrder: $sortOrder) {
                TableColumn("Day", value: \.day) { item in
                    Text(group.hasDay ? item.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) : "–")
                        .foregroundStyle(group.hasDay ? .primary : .tertiary)
                }
                .width(min: 76, ideal: 86)
                TableColumn("Name", value: \.name) { item in
                    HStack(spacing: 6) {
                        if group.hasAccount { Circle().fill(accountColor(item.account)).frame(width: 7, height: 7) }
                        Text(item.name).lineLimit(1)
                    }
                }
                .width(min: 90, ideal: 110)
                if group.hasModel {
                    TableColumn("Model", value: \.model) { item in Text(item.model).foregroundStyle(.secondary) }
                        .width(min: 55, ideal: 70)
                }
                TableColumn("Replies", value: \.replies) { item in number(item.replies.formatted()) }
                    .width(min: 50, ideal: 58)
                TableColumn("Input", value: \.input) { item in number(compact(item.input)) }
                    .width(min: 45, ideal: 52)
                TableColumn("Output", value: \.output) { item in number(compact(item.output)) }
                    .width(min: 45, ideal: 52)
                TableColumn("Cached", value: \.cacheRead) { item in number(compact(item.cacheRead)) }
                    .width(min: 55, ideal: 64)
                TableColumn("API Value", value: \.cost) { item in number(dollars(item.cost)).fontWeight(.medium) }
                    .width(min: 60, ideal: 70)
                TableColumn("Extra Billed", value: \.billedSort) { item in
                    number(item.billed).foregroundStyle(item.billedSort > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
                .width(min: 70, ideal: 84)
            }
            // As tall as its rows, up to a screenful; the table scrolls past that.
            .frame(height: min(420, max(120, 34 + 25 * CGFloat(items.count))))
            Text(billedNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
    }

    private func number(_ text: String) -> some View {
        Text(text).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var billedNote: String {
        let since = model.state.extraByDay.values.compactMap { ExtraLedger.since($0) }.min()
        let from = since.map { String(localized: "since \($0.formatted(date: .abbreviated, time: .omitted))") }
            ?? String(localized: "from tomorrow on")
        return String(localized: "Extra Billed is what claude.ai charged beyond the plan as extra usage, in each account\u{2019}s currency, by day \(from): claude.ai only reports the month so far, so Claude Switcher keeps the daily amounts itself. It is real money; the API value is not.")
    }

    /// The rows of the breakdown for the chosen grouping, from the report's cells.
    private func breakdownItems(_ r: UsageReport) -> [BreakdownItem] {
        let billed = billedByDay()
        if group == .chat {
            let titles = Dictionary(model.insights.chats.map { ($0.conversation, $0.title) }, uniquingKeysWith: { a, _ in a })
            return r.byConversationInRange.map { id, total in
                BreakdownItem(id: id, day: .distantPast, name: titles[id] ?? String(localized: "Terminal or deleted chat"),
                              account: "", model: "", total: total, billed: [:])
            }
        }
        struct Key: Hashable { var day: Date?; var account: String?; var model: String? }
        var sums: [Key: UsageTotal] = [:]
        for cell in r.cells {
            let key = Key(day: group.hasDay ? cell.day : nil, account: group.hasAccount ? cell.account : nil,
                          model: group.hasModel ? cell.model : nil)
            sums[key, default: UsageTotal()].merge(cell.total)
        }
        return sums.map { key, total in
            // Billing is known per account and day; a row covers the days and accounts it groups.
            var money: [String: Double] = [:]
            for (cell, amounts) in billed where (key.day == nil || key.day == cell.day) && (key.account == nil || key.account == cell.account)
                && range.dates.contains(cell.day) && (accounts?.contains(cell.account) ?? true) && key.model == nil {
                for (currency, value) in amounts { money[currency, default: 0] += value }
            }
            let name = key.account.map(accountName) ?? (key.model ?? String(localized: "All"))
            return BreakdownItem(
                id: "\(key.day?.timeIntervalSince1970 ?? 0)|\(key.account ?? "")|\(key.model ?? "")",
                day: key.day ?? .distantPast, name: name, account: key.account ?? "",
                model: key.model ?? (group == .model ? name : "–"), total: total, billed: money)
        }
    }

    /// (day, account) → currency → amount billed that day, in major units.
    private func billedByDay() -> [DayAccount: [String: Double]] {
        var out: [DayAccount: [String: Double]] = [:]
        for (account, monthToDate) in model.state.extraByDay {
            let currency = model.state.account(account)?.usage?.extra?.currency ?? "USD"
            for (day, minor) in ExtraLedger.daily(monthToDate) where minor > 0 {
                out[DayAccount(day: day, account: account), default: [:]][currency, default: 0] += minor / 100
            }
        }
        return out
    }

    // MARK: - Cards

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
                        Image(systemName: id.isEmpty ? "questionmark.circle" : "person.crop.circle.badge.questionmark")
                            .font(.system(size: 20)).foregroundStyle(.secondary).frame(width: 26)
                    }
                    BreakdownRow(title: accountName(id), subtitle: billedLine(account, total),
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
        let rows = r.byConversationInRange.sorted { $0.value.cost > $1.value.cost }.prefix(8)
        let top = rows.first?.value.cost ?? 0
        return Card(title: "Costliest Chats") {
            ForEach(Array(rows), id: \.key) { id, total in
                BreakdownRow(title: titles[id] ?? String(localized: "Terminal or deleted chat"),
                             subtitle: String(localized: "\(compact(total.tokens.total)) tokens · \(total.tokens.messages.formatted()) replies"),
                             value: dollars(total.cost), share: top > 0 ? total.cost / top : 0)
            }
        }
    }
}

struct DayAccount: Hashable {
    var day: Date
    var account: String
}

/// One row of the breakdown table.
struct BreakdownItem: Identifiable {
    let id: String
    let day: Date
    let name: String
    let account: String
    let model: String
    let replies: Int
    let input: Int
    let output: Int
    let cacheRead: Int
    let cost: Double
    /// Currency → amount, in major units.
    let billedAmounts: [String: Double]

    init(id: String, day: Date, name: String, account: String, model: String, total: UsageTotal, billed: [String: Double]) {
        self.id = id
        self.day = day
        self.name = name
        self.account = account
        self.model = model
        replies = total.tokens.messages
        input = total.tokens.input + total.tokens.write5m + total.tokens.write1h
        output = total.tokens.output
        cacheRead = total.tokens.cacheRead
        cost = total.cost
        billedAmounts = billed
    }

    var billed: String {
        billedAmounts.isEmpty ? "–" : billedAmounts.sorted { $0.key < $1.key }.map { money($0.value, $0.key) }.joined(separator: " + ")
    }

    /// Amounts in different currencies cannot be added up, so rows sort by their largest one.
    var billedSort: Double { billedAmounts.values.max() ?? 0 }
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
