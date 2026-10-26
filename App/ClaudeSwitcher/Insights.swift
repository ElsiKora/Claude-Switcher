import Foundation
import Observation
import SwitcherCore

/// One Claude Code chat, from the chat lists of every account.
struct ChatRow: Identifiable, Hashable {
    enum Status: String {
        case working = "Working"
        case open = "Open"
        case cutOff = "Cut off"
        case archived = "Archived"
        case idle = "Idle"
    }

    let id: String
    let conversation: String
    let title: String
    let project: String
    let account: String
    let model: String
    let lastActive: Date
    let status: Status
    let tokens: Int
    let cost: Double
}

/// Token usage and the chat list, read from Claude Code's own files.
@MainActor
@Observable
final class Insights {
    private(set) var buckets: [UsageBucket: Tokens] = [:]
    /// Share of the transcripts read while indexing, nil when done.
    private(set) var progress: Double?
    private(set) var chats: [ChatRow] = []
    private(set) var updatedAt: Date?
    private var running = false
    private let index: UsageIndex

    init(store: Store) {
        index = UsageIndex(cacheURL: store.root.appending(path: "usage-index.json"))
    }

    func refresh(_ model: AppModel) async {
        if model.isDemo {
            buckets = Demo.usage
            chats = Demo.chats(report(.all, timeline: model.timeline))
            updatedAt = .now
            return
        }
        guard !running else { return }
        running = true
        defer { running = false }
        if buckets.isEmpty { progress = 0 }
        let index = index
        let found = await Task.detached { [weak self] in
            await index.refresh { done, total in
                let share = total == 0 ? 1 : Double(done) / Double(total)
                Task { @MainActor in self?.progress = share }
            }
        }.value
        buckets = found
        progress = nil
        updatedAt = .now
        chats = await Self.readChats(model, report: report(.all, timeline: model.timeline))
    }

    /// Reads new transcript records into the buckets, without the chat list:
    /// for the switcher's own use (pace, morning summary).
    func updateBuckets() async {
        guard !running else { return }
        running = true
        defer { running = false }
        let index = index
        buckets = await Task.detached { await index.refresh() }.value
    }

    enum Range: String, CaseIterable, Identifiable {
        case today = "Today", week = "7 Days", month = "30 Days", thisMonth = "This Month", all = "All"
        var id: String { rawValue }

        var dates: ClosedRange<Date> {
            let cal = Calendar.current
            let now = Date.now
            return switch self {
            case .today: cal.startOfDay(for: now)...now
            case .week: cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now))!...now
            case .month: cal.date(byAdding: .day, value: -29, to: cal.startOfDay(for: now))!...now
            // The calendar month, the period claude.ai bills extra usage for.
            case .thisMonth: (cal.dateInterval(of: .month, for: now)?.start ?? now)...now
            case .all: Date.distantPast...now
            }
        }
    }

    func report(_ range: Range, timeline: AccountTimeline, filter: UsageFilter = .all,
                extra: [String: ExtraTrack] = [:]) -> UsageReport {
        UsageReport.make(buckets, timeline: timeline, range: range.dates, filter: filter, extra: extra)
    }

    /// Every chat of every account's list, once, with its latest state.
    private static func readChats(_ model: AppModel, report: UsageReport) async -> [ChatRow] {
        let root = model.engine.desktop.sessionsRoot
        let timeline = model.timeline
        let names = Dictionary(model.accounts.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        let live = ClaudeProcess.liveConversations()
        let byConversation = report.byConversation
        return await Task.detached {
            struct Entry: Decodable {
                var cliSessionId: String?
                var title: String?
                var cwd: String?
                var originCwd: String?
                var model: String?
                var lastActivityAt: Double?
                var isArchived: Bool?
                var interruptedByQuitAt: Double?
            }
            var newest: [String: (Entry, Date)] = [:]
            for account in Files.subdirectories(of: root) {
                for org in Files.subdirectories(of: account) {
                    for name in (try? FileManager.default.contentsOfDirectory(atPath: org.path)) ?? []
                    where name.hasPrefix("local_") && name.hasSuffix(".json") {
                        guard let data = try? Data(contentsOf: org.appending(path: name)),
                              let e = try? JSONDecoder().decode(Entry.self, from: data) else { continue }
                        let date = Date(timeIntervalSince1970: (e.lastActivityAt ?? 0) / 1000)
                        let id = String(name.dropFirst("local_".count).dropLast(".json".count))
                        if newest[id].map({ date > $0.1 }) ?? true { newest[id] = (e, date) }
                    }
                }
            }
            return newest.map { id, value in
                let (e, date) = value
                let cli = e.cliSessionId ?? ""
                let owner = timeline.account(at: date, conversation: cli)
                let status: ChatRow.Status =
                    e.isArchived == true ? .archived
                    : e.interruptedByQuitAt != nil ? .cutOff
                    : live.runningCommands.contains(cli) ? .working
                    : live.ids.contains(cli) ? .open : .idle
                let total = byConversation[cli]
                let folder = (e.originCwd ?? e.cwd).map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
                return ChatRow(
                    id: id, conversation: cli, title: e.title ?? String(localized: "Untitled"), project: folder,
                    account: owner.flatMap { names[$0] } ?? String(localized: "Other"),
                    model: e.model.map(Pricing.displayName) ?? "", lastActive: date, status: status,
                    tokens: total?.tokens.total ?? 0, cost: total?.cost ?? 0)
            }
            .sorted { $0.lastActive > $1.lastActive }
        }.value
    }
}
