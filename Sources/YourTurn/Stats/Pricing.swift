import Foundation

/// Per-token rates for one model, in USD. Field names are this app's, not LiteLLM's — the
/// mapping happens once, in `PriceTable`.
struct ModelPrice: Sendable, Codable, Equatable {
    let input: Double
    let output: Double
    /// Optional rather than defaulted to 0: a model that genuinely has no cache pricing and a
    /// price entry that simply omitted the field are different things, and only the first one
    /// should silently cost nothing.
    let cacheRead: Double?
    let cacheWrite: Double?
    let cacheWrite1h: Double?
}

/// A cost broken down by which token bucket it came from.
///
/// Worth carrying separately from a single total because the two shares disagree
/// dramatically — measured here, cache reads are 97% of all tokens but nowhere near 97% of
/// the bill, and that gap is the most useful thing this app can tell someone about their
/// spending.
struct CostSplit: Sendable, Equatable {
    var input = 0.0
    var output = 0.0
    var cacheRead = 0.0
    var cacheWrite = 0.0

    var total: Double { input + output + cacheRead + cacheWrite }

    static func + (a: CostSplit, b: CostSplit) -> CostSplit {
        CostSplit(
            input: a.input + b.input, output: a.output + b.output,
            cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite
        )
    }

    static func += (a: inout CostSplit, b: CostSplit) { a = a + b }
}

/// Turns token counts into dollars.
///
/// The whole algorithm is two lines deep: price one bucket of tokens, then walk a request's
/// segments. What makes it accurate is *what* it walks — per iteration, each at its own
/// model. The source research measured this against Claude Code's own reported cost across
/// 21,299 requests: pricing the top-level `usage` directly lands at 1.767% total error,
/// per-iteration + per-model at **0.310%**, with a per-request median error of 0.0000%.
enum Pricing {
    /// Returns nil when any segment's model has no price. **Never silently zero** — the worst
    /// failure mode for an accounting tool is being quietly wrong, and unpriced models do turn
    /// up in real data (measured: 129 `<synthetic>` records, which are Claude Code's own local
    /// responses rather than API calls).
    static func split(_ record: UsageRecord, prices: PriceTable) -> CostSplit? {
        var total = CostSplit()
        for segment in record.segments {
            guard let price = prices.price(for: segment.model) else { return nil }
            total += split(segment.tokens, price)
        }
        return total
    }

    static func cost(_ record: UsageRecord, prices: PriceTable) -> Double? {
        split(record, prices: prices)?.total
    }

    static func split(_ tokens: TokenCounts, _ price: ModelPrice) -> CostSplit {
        // Spelled out one assignment at a time, not as one expression: SourceKit reports
        // "unable to type-check in reasonable time" on the chained version — five Int→Double
        // conversions and three `??` defaults in a single expression is past its budget.
        var result = CostSplit()
        result.input = Double(tokens.input) * price.input
        result.output = Double(tokens.output) * price.output
        result.cacheRead = Double(tokens.cacheRead) * (price.cacheRead ?? 0)
        result.cacheWrite = Double(tokens.cacheWrite5m) * (price.cacheWrite ?? 0)
        // The 1h tier falls back to the 5m rate rather than to 0: older price entries have no
        // 1h field, and charging nothing for a real token is the failure mode to avoid.
        let hourly = price.cacheWrite1h ?? price.cacheWrite ?? 0
        result.cacheWrite += Double(tokens.cacheWrite1h) * hourly
        return result
    }

    static func cost(_ tokens: TokenCounts, _ price: ModelPrice) -> Double {
        split(tokens, price).total
    }
}
