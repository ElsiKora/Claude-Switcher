import SwiftUI
import SwitcherCore

/// Every Claude Code chat of every account in one table: search, sort, and
/// open one in Claude.
struct ChatsView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\ChatRow.lastActive, order: .reverse)]
    @State private var selection: Set<ChatRow.ID> = []
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", active = "Active", cutOff = "Cut Off", archived = "Archived"
        var id: String { rawValue }
    }

    private var rows: [ChatRow] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return model.insights.chats
            .filter { row in
                switch filter {
                case .all: row.status != .archived
                case .active: row.status == .working || row.status == .open
                case .cutOff: row.status == .cutOff
                case .archived: row.status == .archived
                }
            }
            .filter { q.isEmpty || "\($0.title) \($0.project) \($0.account) \($0.model)".lowercased().contains(q) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        let rows = rows
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Chat", value: \.title) { row in
                HStack(spacing: 8) {
                    StatusDot(status: row.status)
                    Text(row.title).lineLimit(1)
                }
            }
            .width(min: 180, ideal: 240)
            TableColumn("Account", value: \.account).width(min: 70, ideal: 90)
            TableColumn("Project", value: \.project).width(min: 60, ideal: 80)
            TableColumn("Model", value: \.model).width(min: 60, ideal: 70)
            TableColumn("Last Active", value: \.lastActive) { row in
                Text(row.lastActive.formatted(.relative(presentation: .named))).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 110)
            TableColumn("Tokens", value: \.tokens) { row in
                Text(row.tokens == 0 ? "–" : compact(row.tokens)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 70)
            TableColumn("API Value", value: \.cost) { row in
                Text(row.cost == 0 ? "–" : dollars(row.cost)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 80)
            TableColumn("Status", value: \.status.rawValue) { row in
                Text(LocalizedStringKey(row.status.rawValue)).foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 80)
        }
        .contextMenu(forSelectionType: ChatRow.ID.self) { ids in
            Button("Open in Claude") { open(ids) }
        } primaryAction: { ids in
            open(ids)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search chats")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $filter) { ForEach(Filter.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                    .pickerStyle(.segmented)
            }
        }
        .overlay {
            if model.insights.chats.isEmpty, model.insights.progress != nil {
                ProgressView("Reading chats\u{2026}")
            } else if rows.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .navigationTitle("Chats")
        .navigationSubtitle(Text("\(rows.count) chats"))
        .task { await model.insights.refresh(model) }
    }

    private func open(_ ids: Set<ChatRow.ID>) {
        for id in ids.prefix(5) {
            if let url = URL(string: "claude://code/continue?session=local_\(id)") { NSWorkspace.shared.open(url) }
        }
    }
}

private struct StatusDot: View {
    let status: ChatRow.Status

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .help(Text(LocalizedStringKey(status.rawValue)))
    }

    private var color: Color {
        switch status {
        case .working: .green
        case .open: .blue
        case .cutOff: .orange
        case .archived: .gray
        case .idle: .secondary.opacity(0.4)
        }
    }
}
