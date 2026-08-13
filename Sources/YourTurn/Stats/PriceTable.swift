import Foundation

/// Where the model prices came from.
///
/// LiteLLM's `model_prices_and_context_window.json` is the same source ccusage prices against,
/// and it already carries the cache tiers this app needs, 1:1 with the transcript's fields —
/// no model-name mapping table required, the `model` string in the JSONL is the key.
///
/// A trimmed snapshot ships inside the app (measured: 26 Anthropic models, 4.3KB, versus
/// 3,003 models and 1.6MB for the whole file) so the numbers work offline and on first launch.
/// The live copy is only ever an improvement on it, never a prerequisite.
struct PriceTable: Sendable, Equatable {
    enum Source: Sendable, Equatable {
        case bundled
        case downloaded
    }

    let models: [String: ModelPrice]
    /// The `updated` stamp written into the file, `yyyy-MM-dd`. Shown in the UI so "this is
    /// an estimate priced against a table from date X" stays visible.
    let updated: String
    let source: Source

    func price(for model: String) -> ModelPrice? { models[model] }

    static let empty = PriceTable(models: [:], updated: "", source: .bundled)

    // MARK: - Loading

    /// Cached download first, bundled snapshot second. A corrupt or empty cache falls through
    /// to the bundle rather than leaving the app with no prices at all.
    static func load() -> PriceTable {
        if let data = try? Data(contentsOf: cacheURL),
           let table = decode(data, source: .downloaded), !table.models.isEmpty {
            return table
        }
        return bundled()
    }

    static func bundled() -> PriceTable {
        guard let url = Bundle.module.url(forResource: "prices", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let table = decode(data, source: .bundled)
        else { return .empty }
        return table
    }

    // MARK: - Refreshing

    static let remoteURL = URL(
        string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
    )!

    /// Downloads LiteLLM's table, trims it to the Anthropic models, and caches the result.
    ///
    /// One of the app's two network requests (the other is `UpdateCheck`). It sends a bare GET
    /// to a public GitHub raw URL and carries nothing about the user — no session data, no
    /// project names, no counts.
    /// Failure is not an error state: the bundled snapshot already priced everything, so a
    /// refresh that doesn't come back just leaves the numbers as they were.
    static func refresh() async -> PriceTable? {
        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let trimmed = trim(data)
        else { return nil }

        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if let encoded = try? JSONEncoder().encode(trimmed) {
            try? encoded.write(to: cacheURL, options: .atomic)
        }
        return PriceTable(models: trimmed.models, updated: trimmed.updated, source: .downloaded)
    }

    /// Keeps only `litellm_provider == "anthropic"` entries that actually have input+output
    /// rates. Dropping the other 2,977 models is what turns a 1.6MB download into a 4KB cache.
    private static func trim(_ data: Data) -> Wire? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var models: [String: ModelPrice] = [:]
        for (name, value) in raw {
            guard let entry = value as? [String: Any],
                  entry["litellm_provider"] as? String == "anthropic",
                  let input = entry["input_cost_per_token"] as? Double,
                  let output = entry["output_cost_per_token"] as? Double
            else { continue }
            models[name] = ModelPrice(
                input: input,
                output: output,
                cacheRead: entry["cache_read_input_token_cost"] as? Double,
                cacheWrite: entry["cache_creation_input_token_cost"] as? Double,
                cacheWrite1h: entry["cache_creation_input_token_cost_above_1hr"] as? Double
            )
        }
        guard !models.isEmpty else { return nil }
        return Wire(updated: today(), models: models)
    }

    private static func today() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    // MARK: - Storage

    /// This app's own Application Support directory, matching `ArchiveStore` — `~/.claude`
    /// stays read-only.
    static let cacheURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "YourTurn/prices.json")
    }()

    /// The on-disk shape, shared by the bundled snapshot and the cached download.
    private struct Wire: Codable {
        let updated: String
        let models: [String: ModelPrice]
    }

    private static func decode(_ data: Data, source: Source) -> PriceTable? {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        return PriceTable(models: wire.models, updated: wire.updated, source: source)
    }
}
