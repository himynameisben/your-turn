import Foundation

/// Reads every billable request out of `~/.claude/projects`.
///
/// This is a **second, separate pipeline** from `SessionScanner`, and the two disagree on all
/// three of the things that matter — merging them would break both:
///
/// | | `SessionScanner` | here |
/// |---|---|---|
/// | how much of a file | last 64KB | all of it |
/// | `<uuid>/subagents/` | never descends (it would inflate the session count) | descends (measured 10,183 requests / 1.54G tokens, about a quarter of the total) |
/// | when it runs | every 30 seconds | only when the stats window is open, and cached |
///
/// Measured cost of a full pass over a 1.0GB `~/.claude/projects`: 591 files in 4.05s
/// single-threaded (Python reference implementation). The bottleneck is CPU scanning bytes,
/// not disk, so it runs on `concurrentPerform`; `UsageCache` then keeps repeat scans near zero.
enum UsageScanner {
    struct Result: Sendable {
        var records: [UsageRecord] = []
        var turns: [TurnRecord] = []
        var files = 0
        var filesFromCache = 0
        var bytesRead = 0
        /// Same-`requestId` rows collapsed within a single file. Measured 48% of all rows.
        var duplicateRows = 0
        /// The same `requestId` turning up in two different files — a forked or resumed
        /// session copies the transcript. Measured 166 of 36,265 (0.46%), which is why
        /// deduplication has to happen after the merge and not per file.
        var crossFileDuplicates = 0
        var duration: TimeInterval = 0
    }

    static func scan(cache: UsageCache? = nil) -> Result {
        let started = Date()
        let files = usageFiles()
        guard !files.isEmpty else { return Result() }

        var parsed = [FileUsage?](repeating: nil, count: files.count)
        var fromCache = [Bool](repeating: false, count: files.count)
        var sizes = [Int](repeating: 0, count: files.count)

        parsed.withUnsafeMutableBufferPointer { output in
            fromCache.withUnsafeMutableBufferPointer { cached in
                sizes.withUnsafeMutableBufferPointer { byteCount in
                    let out = UncheckedSendable(output)
                    let hit = UncheckedSendable(cached)
                    let bytes = UncheckedSendable(byteCount)
                    DispatchQueue.concurrentPerform(iterations: files.count) { i in
                        let file = files[i]
                        if let stored = cache?.value(for: file.url, stamp: file.stamp) {
                            out.value[i] = stored
                            hit.value[i] = true
                            return
                        }
                        out.value[i] = parse(file.url, isSubagent: file.isSubagent)
                        bytes.value[i] = file.stamp.size
                    }
                }
            }
        }

        var result = Result()
        result.files = files.count
        result.filesFromCache = fromCache.count { $0 }
        result.bytesRead = sizes.reduce(0, +)

        // Dedup across files, not just within them: `requestId` is the identity of one API
        // call, and a forked session's transcript carries the original's rows verbatim.
        var index: [String: Int] = [:]
        index.reserveCapacity(40_000)
        for (i, file) in parsed.enumerated() {
            guard let file else { continue }
            if !fromCache[i] { cache?.store(file, for: files[i].url, stamp: files[i].stamp) }
            result.duplicateRows += file.duplicateRows
            result.turns.append(contentsOf: file.turns)
            for record in file.records {
                guard let existing = index[record.requestId] else {
                    index[record.requestId] = result.records.count
                    result.records.append(record)
                    continue
                }
                result.crossFileDuplicates += 1
                if record.tokens.output > result.records[existing].tokens.output {
                    result.records[existing] = record
                }
            }
        }
        result.records.sort { $0.timestamp < $1.timestamp }
        result.turns.sort { $0.timestamp < $1.timestamp }
        cache?.retain(Set(files.map(\.url.path)))
        cache?.save()
        result.duration = Date().timeIntervalSince(started)
        return result
    }

    // MARK: - File discovery

    struct Stamp: Sendable, Equatable {
        let size: Int
        let modified: Date
    }

    private struct File: Sendable {
        let url: URL
        let isSubagent: Bool
        let stamp: Stamp
    }

    /// Two shapes hold billable records: `projects/<slug>/<uuid>.jsonl` for the session
    /// itself, and `projects/<slug>/<uuid>/subagents/agent-*.jsonl` for everything it fanned
    /// out to. Nothing else under `projects/` is enumerated — the walk is explicit about both
    /// shapes rather than recursive, so a new subdirectory can't silently start counting.
    private static func usageFiles() -> [File] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let slugs = try? fm.contentsOfDirectory(
            at: SessionScanner.projectsRoot, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [File] = []
        for slug in slugs {
            guard isDirectory(slug), let entries = try? fm.contentsOfDirectory(
                at: slug, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries {
                if entry.pathExtension == "jsonl", let stamp = stamp(entry) {
                    files.append(File(url: entry, isSubagent: false, stamp: stamp))
                    continue
                }
                guard isDirectory(entry) else { continue }
                let subagents = entry.appending(path: "subagents", directoryHint: .isDirectory)
                guard let agents = try? fm.contentsOfDirectory(
                    at: subagents, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
                ) else { continue }
                for agent in agents where agent.pathExtension == "jsonl" {
                    guard let stamp = stamp(agent) else { continue }
                    files.append(File(url: agent, isSubagent: true, stamp: stamp))
                }
            }
        }
        return files
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private static func stamp(_ url: URL) -> Stamp? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate
        else { return nil }
        return Stamp(size: size, modified: modified)
    }

    // MARK: - Parsing

    /// Bytes that must appear in a line before it's worth handing to the JSON parser.
    ///
    /// This is the single optimization that makes a full pass viable: only ~1 line in 10
    /// carries usage, and `json.loads` on the rest costs more than the entire scan. The
    /// substring test is cheap and its false positives (a message body that happens to
    /// contain the word) are dropped by the type checks below.
    private static let usageNeedle = Array(#""usage""#.utf8)
    private static let turnNeedle = Array("turn_duration".utf8)

    static func parse(_ url: URL, isSubagent: Bool) -> FileUsage? {
        // Memory-mapped: the largest single transcript measured 46MB, and a full scan touches
        // 1.0GB. Mapping lets the kernel page it rather than materializing it all in the heap.
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }

        var file = FileUsage()
        var index: [String: Int] = [:]

        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = 0
            for i in 0..<bytes.count where bytes[i] == 0x0A {
                consume(bytes, start..<i, isSubagent: isSubagent, into: &file, index: &index)
                start = i + 1
            }
            if start < bytes.count {
                consume(bytes, start..<bytes.count, isSubagent: isSubagent, into: &file, index: &index)
            }
        }
        return file
    }

    private static func consume(
        _ bytes: UnsafeBufferPointer<UInt8>,
        _ range: Range<Int>,
        isSubagent: Bool,
        into file: inout FileUsage,
        index: inout [String: Int]
    ) {
        guard !range.isEmpty else { return }
        let hasUsage = contains(bytes, range, usageNeedle)
        let hasTurn = contains(bytes, range, turnNeedle)
        guard hasUsage || hasTurn else { return }

        guard let object = try? JSONSerialization.jsonObject(
            with: Data(bytes[range])
        ) as? [String: Any] else { return }

        guard let timestamp = (object["timestamp"] as? String).flatMap(ISOTimestamp.parse),
              let sessionId = object["sessionId"] as? String,
              let projectPath = object["cwd"] as? String
        else { return }

        if hasTurn, object["subtype"] as? String == "turn_duration" {
            let ms = (object["durationMs"] as? NSNumber)?.doubleValue ?? 0
            file.turns.append(TurnRecord(
                sessionId: sessionId, timestamp: timestamp,
                duration: ms / 1000, projectPath: projectPath
            ))
            return
        }

        guard let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return }

        // Measured: 11 of 50,682 usage rows carry no `requestId`. Falling back to the record's
        // own uuid keeps them counted; they just can't be deduplicated against anything.
        let requestId = object["requestId"] as? String
            ?? object["uuid"] as? String
            ?? UUID().uuidString

        let record = UsageRecord(
            requestId: requestId,
            timestamp: timestamp,
            sessionId: sessionId,
            projectPath: projectPath,
            isSubagent: isSubagent,
            segments: segments(model: message["model"] as? String ?? "", usage: usage)
        )
        if let existing = index[requestId] {
            file.duplicateRows += 1
            if record.tokens.output > file.records[existing].tokens.output {
                file.records[existing] = record
            }
            return
        }
        index[requestId] = file.records.count
        file.records.append(record)
    }

    /// One request splits into segments only when `usage.iterations` is present — see
    /// `UsageSegment` for why the top-level totals can't be trusted in that case.
    private static func segments(model: String, usage: [String: Any]) -> [UsageSegment] {
        guard let iterations = usage["iterations"] as? [[String: Any]], !iterations.isEmpty else {
            return [UsageSegment(model: model, tokens: counts(usage))]
        }
        return iterations.map {
            UsageSegment(model: $0["model"] as? String ?? model, tokens: counts($0))
        }
    }

    private static func counts(_ usage: [String: Any]) -> TokenCounts {
        var tokens = TokenCounts()
        tokens.input = int(usage["input_tokens"])
        tokens.output = int(usage["output_tokens"])
        tokens.cacheRead = int(usage["cache_read_input_tokens"])
        if let creation = usage["cache_creation"] as? [String: Any] {
            tokens.cacheWrite5m = int(creation["ephemeral_5m_input_tokens"])
            tokens.cacheWrite1h = int(creation["ephemeral_1h_input_tokens"])
        } else {
            // Records predating the tiered fields: the flat total is all 5-minute cache.
            tokens.cacheWrite5m = int(usage["cache_creation_input_tokens"])
        }
        return tokens
    }

    private static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }

    /// Naive substring search over a line's bytes. Lines are a few KB at most and the needles
    /// are under 14 bytes, so there's nothing here for a smarter algorithm to save.
    private static func contains(
        _ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>, _ needle: [UInt8]
    ) -> Bool {
        let limit = range.upperBound - needle.count
        guard limit >= range.lowerBound else { return false }
        var i = range.lowerBound
        while i <= limit {
            if bytes[i] == needle[0] {
                var j = 1
                while j < needle.count, bytes[i + j] == needle[j] { j += 1 }
                if j == needle.count { return true }
            }
            i += 1
        }
        return false
    }
}
