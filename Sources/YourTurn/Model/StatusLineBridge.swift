import Foundation

/// The one thing Your Turn ever writes into `~/.claude`, and only while you have it switched on.
///
/// Claude Code publishes a subscription's rate limits in exactly one place: the JSON it hands
/// its status line command on stdin. Measured, nothing on disk carries them — `projects/*.jsonl`
/// plus `cache/`, `telemetry/`, `daemon/`, `jobs/` and `session-env/` were all searched for
/// `five_hour` / `seven_day` / `rate_limit` and came back empty. The only other route is the
/// account API, which means lifting an OAuth token out of the login keychain, and measured, a
/// second app reading `Claude Code-credentials` raises a macOS consent dialog. So: a status
/// line, installed deliberately, rather than a credential read that looks like snooping.
///
/// Everything about it is reversible from the same switch, and nothing about it is cached —
/// `state()` re-reads `settings.json` every time, for the same reason `LaunchAtLogin` re-reads
/// `SMAppService`: a stored copy of somebody else's file is a copy that can be wrong.
enum StatusLineBridge {
    /// Where the shipped script is copied to, and where it leaves its readings.
    ///
    /// Deliberately *not* run from inside the .app: `settings.json` would then hold a path that
    /// breaks the moment the app is moved out of /Applications, and it would break silently —
    /// Claude Code just shows an empty status line. Application Support doesn't move.
    static var supportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "YourTurn", directoryHint: .isDirectory)
    }

    static var scriptURL: URL { supportDirectory.appending(path: "statusline-bridge.sh") }
    static var payloadURL: URL { supportDirectory.appending(path: "claude-allowance.json") }
    static var settingsURL: URL { URL.homeDirectory.appending(path: ".claude/settings.json") }

    enum State: Equatable {
        case off
        /// Ours, carrying whatever status line it replaced.
        case on(chained: String?)
        /// Somebody else's. Switching on chains to it rather than replacing it.
        case foreign(command: String)
    }

    static func state() -> State {
        guard let settings = readSettings(),
              let line = settings["statusLine"] as? [String: Any],
              let command = line["command"] as? String
        else { return .off }
        let parsed = parse(command)
        guard parsed.isOurs else { return .foreign(command: command) }
        return .on(chained: parsed.chained)
    }

    static var isOn: Bool { if case .on = state() { return true } else { return false } }

    /// Copies the script out and points `statusLine` at it, keeping any existing command as the
    /// script's one argument.
    ///
    /// The script is rewritten on every enable rather than only when missing, so an app update
    /// ships a new bridge without needing its own migration.
    static func enable() throws {
        let previous: String?
        switch state() {
        case .off: previous = nil
        case .on(let chained): previous = chained
        case .foreign(let command): previous = command
        }

        try installScript()

        var command = quote(scriptURL.path(percentEncoded: false))
        if let previous, !previous.isEmpty { command += " " + quote(previous) }

        var settings = readSettings() ?? [:]
        settings["statusLine"] = ["type": "command", "command": command]
        try writeSettings(settings)
    }

    /// Puts back exactly what was there before, which for most people is nothing at all.
    static func disable() throws {
        guard case .on(let chained) = state() else { return }
        var settings = readSettings() ?? [:]
        if let chained, !chained.isEmpty {
            settings["statusLine"] = ["type": "command", "command": chained]
        } else {
            settings.removeValue(forKey: "statusLine")
        }
        try writeSettings(settings)
        try? FileManager.default.removeItem(at: scriptURL)
        try? FileManager.default.removeItem(at: payloadURL)
    }

    // MARK: - The script

    private static func installScript() throws {
        guard let source = Bundle.module.url(forResource: "statusline-bridge", withExtension: "sh")
        else { throw Failure.scriptMissing }
        try FileManager.default.createDirectory(
            at: supportDirectory, withIntermediateDirectories: true
        )
        let script = try Data(contentsOf: source)
        try script.write(to: scriptURL, options: .atomic)
        // `.process("Resources")` doesn't carry the executable bit across, and `statusLine`
        // runs the path directly rather than through a shell.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path(percentEncoded: false)
        )
    }

    enum Failure: Error { case scriptMissing, unreadableSettings }

    // MARK: - settings.json

    private static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Refuses rather than clobbers: a `settings.json` that won't parse is one that somebody is
    /// mid-edit on, and rewriting it from an empty dictionary would delete their whole file.
    ///
    /// Splices one line into the existing text where it can, and reserializes the whole object
    /// only when it can't. Measured: reserializing a 4.8KB `settings.json` rewrites every byte of
    /// it — `JSONSerialization` has no insertion order to preserve, so `.sortedKeys` is the only
    /// deterministic option and it reorders everything, and it writes `"key" : value` with a
    /// space before the colon on top of that. Flipping one switch shouldn't produce a whole-file
    /// diff in somebody's dotfiles repo.
    ///
    /// The splice is only ever attempted against text that provably doesn't contain the key
    /// already, and **the result is parsed back and compared to the object that was meant to be
    /// written** before it's allowed anywhere near the disk. A splice that goes wrong falls back
    /// to the reserialize, so the worst case is the reformat rather than a corrupt file.
    private static func writeSettings(_ settings: [String: Any]) throws {
        let existing = try? String(contentsOf: settingsURL, encoding: .utf8)
        if existing != nil, readSettings() == nil { throw Failure.unreadableSettings }

        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        if let existing, let spliced = splice(settings, into: existing),
           let data = spliced.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           NSDictionary(dictionary: parsed) == NSDictionary(dictionary: settings) {
            try Data(spliced.utf8).write(to: settingsURL, options: .atomic)
            return
        }

        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: settingsURL, options: .atomic)
    }

    /// Adds, replaces or removes exactly the one member this type owns, textually.
    ///
    /// Every branch bails to `nil` — and so to the reserialize — the moment the file doesn't look
    /// the way it expects, because "I couldn't find it" and "I found something I didn't write"
    /// are the same answer here: don't guess at somebody's hand-edited JSON. A `statusLine`
    /// written across several lines, the way a person would format one, lands in exactly that
    /// case and gets the safe path.
    private static func splice(_ settings: [String: Any], into original: String) -> String? {
        var lines = original.components(separatedBy: "\n")
        let existing = lines.enumerated().filter { $0.element.contains("\"statusLine\"") }
        guard existing.count <= 1 else { return nil }

        guard let wanted = settings["statusLine"] else {
            guard let (index, line) = existing.first.map({ ($0.offset, $0.element) })
            else { return original }
            lines.remove(at: index)
            // A member carries its own trailing comma, so pulling one out is usually enough. The
            // exception is the *last* member: it has no comma of its own, and the one above it
            // only had one because this line followed.
            if !line.hasSuffix(","), index > 0, lines[index - 1].hasSuffix(",") {
                lines[index - 1].removeLast()
            }
            return lines.joined(separator: "\n")
        }

        guard let value = try? JSONSerialization.data(
            withJSONObject: wanted, options: [.sortedKeys, .withoutEscapingSlashes]
        ), let text = String(data: value, encoding: .utf8) else { return nil }
        let member = "\"statusLine\": " + text

        // Replacing in place: keeps the indentation and the comma the old line already had, which
        // is what makes switching *off* while chained a one-line diff too.
        if let (index, line) = existing.first.map({ ($0.offset, $0.element) }) {
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            lines[index] = indent + member + (line.hasSuffix(",") ? "," : "")
            return lines.joined(separator: "\n")
        }

        // Adding: straight after the opening brace, so nothing that was already there moves.
        guard let brace = original.firstIndex(of: "{") else { return nil }
        let rest = original[original.index(after: brace)...]
        let isEmptyObject = rest.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("}")
        return String(original[...brace]) + "\n  " + member
            + (isEmptyObject ? "\n" : ",") + String(rest)
    }

    // MARK: - Quoting

    /// What was there before is kept **inside the command string** rather than in preferences of
    /// our own. Same reasoning as `LaunchAtLogin`: state stored on our side can end up disagreeing
    /// with the file, and here the disagreement would be silent and would eat somebody's status
    /// line. The command is self-describing, so switching off can always undo exactly what
    /// switching on did.
    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    private static func unquote(_ value: String) -> String? {
        guard value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") else { return nil }
        return String(value.dropFirst().dropLast()).replacingOccurrences(of: #"'\''"#, with: "'")
    }

    // MARK: - CLI

    /// `--status-line [on|off]` — the verification entry point for this setting.
    ///
    /// It exists because this is the one thing in the app that edits a file it doesn't own, and
    /// the property that matters isn't "does it install" but "does switching it off put back
    /// exactly what was there". Diffing `settings.json` across `off → on → off` is the only way
    /// to see that, and doing it through the UI means a status line appearing in every open
    /// Claude Code window while you look.
    static func cli(_ argument: String?) {
        switch argument {
        case "on":
            do { try enable() } catch { print("failed: \(error)") }
        case "off":
            do { try disable() } catch { print("failed: \(error)") }
        default: break
        }
        switch state() {
        case .off:
            print("status line   off")
        case .on(let chained):
            print("status line   on" + (chained.map { ", chained to \($0)" } ?? ""))
        case .foreign(let command):
            print("status line   not ours: \(command)")
        }
        print("script        \(FileManager.default.fileExists(atPath: scriptURL.path(percentEncoded: false)) ? "installed" : "absent") at \(scriptURL.path(percentEncoded: false))")
        let quotas = ClaudeQuotaReader.read()
        // English, like every other CLI entry point: `AgentQuota.windowLabel` goes through `L()`,
        // and a verification tool whose columns change language with the machine can't be grepped.
        print("reading       " + (quotas.isEmpty
            ? "none yet"
            : quotas.map { quota in
                let window = quota.windowMinutes >= 1440
                    ? "\(quota.windowMinutes / 1440)d" : "\(quota.windowMinutes / 60)h"
                return "\(window) \(Int(quota.remainingPercent))% left"
            }.joined(separator: " · ")))
    }

    private static func parse(_ command: String) -> (isOurs: Bool, chained: String?) {
        let prefix = quote(scriptURL.path(percentEncoded: false))
        guard command.hasPrefix(prefix) else { return (false, nil) }
        let rest = command.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return (true, rest.isEmpty ? nil : unquote(rest))
    }
}
