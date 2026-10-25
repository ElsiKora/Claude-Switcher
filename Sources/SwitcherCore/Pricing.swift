import Foundation

/// Anthropic's first-party API prices per million tokens, to say what a
/// subscription's usage would have cost through the API. One table, with
/// the date it was taken; models not in it are shown without a price.
public enum Pricing {
    /// Where and when the prices come from.
    public static let source = "Anthropic API prices as of 2026-10-06"

    public struct Rates: Sendable, Equatable {
        public var input: Double
        public var output: Double
        /// Cache reads; most models charge a tenth of input, some less.
        public var cacheRead: Double
        public var cacheWrite5m: Double { input * 1.25 }
        public var cacheWrite1h: Double { input * 2 }
    }

    /// Prices by model id prefix, longest match first.
    static let table: [(prefix: String, rates: Rates)] = [
        ("claude-fable-5-1", Rates(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-mythos-5-1", Rates(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-fable-5", Rates(input: 10, output: 50, cacheRead: 1.0)),
        ("claude-opus-5-5", Rates(input: 4, output: 20, cacheRead: 0.20)),
        ("claude-opus-5", Rates(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-opus-4-8", Rates(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-opus-4-7", Rates(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-opus-4-6", Rates(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-sonnet-5-5", Rates(input: 2, output: 10, cacheRead: 0.20)),
        ("claude-sonnet-5", Rates(input: 2, output: 10, cacheRead: 0.20)),
        ("claude-sonnet-4-6", Rates(input: 3, output: 15, cacheRead: 0.30)),
        ("claude-haiku-5-5", Rates(input: 0.10, output: 0.50, cacheRead: 0.01)),
        ("claude-haiku-4-5", Rates(input: 1, output: 5, cacheRead: 0.10)),
    ]

    /// Fast mode on Claude Opus 5.5 is priced at twice the standard rates.
    static let fastMultiplier: [String: Double] = ["claude-opus-5-5": 2]

    public static func rates(for model: String) -> Rates? {
        table.first { model.hasPrefix($0.prefix) }?.rates
    }

    /// Whether one request's prompt is long enough for the long-prompt
    /// price: over 100K tokens on Claude Haiku 5.5. Decided per request,
    /// never on a sum of requests.
    public static func isLongPrompt(model: String, promptTokens: Int) -> Bool {
        model.hasPrefix("claude-haiku-5-5") && promptTokens > 100_000
    }

    /// What usage costs at API prices, in dollars. `longPrompt` is for
    /// requests `isLongPrompt` picked, which cost five times as much.
    public static func cost(model: String, input: Int, output: Int, cacheRead: Int, cacheWrite5m: Int, cacheWrite1h: Int,
                            fast: Bool = false, longPrompt: Bool = false) -> Double? {
        guard let r = rates(for: model) else { return nil }
        var scale = fast ? (fastMultiplier.first { model.hasPrefix($0.key) }?.value ?? 1) : 1
        if longPrompt { scale *= 5 }
        let millions = 1_000_000.0
        return scale * (Double(input) * r.input + Double(output) * r.output + Double(cacheRead) * r.cacheRead
            + Double(cacheWrite5m) * r.cacheWrite5m + Double(cacheWrite1h) * r.cacheWrite1h) / millions
    }

    /// A short name for a model id, for charts: "Opus 5.5".
    public static func displayName(_ model: String) -> String {
        let parts = model.replacing("claude-", with: "").split(separator: "-")
        guard let family = parts.first else { return model }
        let version = parts.dropFirst().prefix { $0.count <= 2 && Int($0) != nil }.joined(separator: ".")
        return family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " " + version)
    }
}
