import AppKit
import Foundation
import Observation

/// Is there a newer release than the one running?
///
/// Deliberately **not** Sparkle. This app ships with no third-party packages, and an
/// auto-updater brings an appcast, a second signing key and an installer helper along with
/// it. What's actually missing without one is much smaller: nobody ever quits a menu bar
/// app, so someone running 0.1.0 never finds out 0.2.0 exists. This closes that gap and
/// nothing else — it compares two version numbers and hands you the release page. People who
/// installed through the Homebrew cask get the real thing from `brew upgrade` anyway.
@Observable
@MainActor
final class UpdateCheck {
    struct Release: Sendable, Equatable {
        /// Without the tag's `v` prefix, so it can be compared to `CFBundleShortVersionString`.
        let version: String
        let page: URL
    }

    enum State: Equatable {
        /// Nothing known yet — or the running copy has no version to compare against.
        case unknown
        case upToDate
        case available(Release)
    }

    private(set) var state: State = .unknown

    /// The throttle below bounds requests over time; this bounds them per launch, so a
    /// failed check costs one request rather than one per view that asks.
    private var checkedThisLaunch = false

    private let defaults = UserDefaults.standard
    private enum Key {
        static let lastCheck = "updateCheckLast"
        static let latestVersion = "updateCheckLatestVersion"
        static let latestPage = "updateCheckLatestPage"
    }

    // MARK: - Checking

    /// Publishes what was already known, then fetches at most once a day.
    ///
    /// Ordered this way so the answer survives being offline: the last known release is
    /// re-compared against the running version on every launch, which also means installing
    /// the new build clears the notice on its own — there's no stored "dismissed" flag that
    /// could disagree with what's actually installed.
    func checkIfNeeded() async {
        guard let current = Self.currentVersion else { return }
        adopt(Self.cachedRelease, current: current)
        guard !checkedThisLaunch, isStale else { return }
        checkedThisLaunch = true
        await check()
    }

    func check() async {
        guard let current = Self.currentVersion,
              case .success(let release) = await Self.fetchLatest()
        else { return }
        // Stamped only on success on purpose: a machine that was offline this morning should
        // be able to find out this afternoon, and `checkedThisLaunch` already caps a failing
        // network at one request per launch.
        defaults.set(Date(), forKey: Key.lastCheck)
        defaults.set(release.version, forKey: Key.latestVersion)
        defaults.set(release.page.absoluteString, forKey: Key.latestPage)
        adopt(release, current: current)
    }

    /// `--render --demo` only. The notice is invisible in a default render — the running copy
    /// is current, which is the whole point — and layout that can't be seen can't be checked.
    /// Mirrors `SessionStore.loadDemo`.
    func loadDemo(_ release: Release) { state = .available(release) }

    private func adopt(_ release: Release?, current: String) {
        guard let release else { return }
        state = Self.isNewer(release.version, than: current) ? .available(release) : .upToDate
    }

    /// Daily. Releases land weeks apart, and this runs in a process that stays up for days —
    /// checking more often is all traffic and no news.
    private var isStale: Bool {
        guard let last = Self.lastCheck else { return true }
        return Date().timeIntervalSince(last) > 86_400
    }

    // MARK: - Storage
    //
    // Static and nonisolated so `--update-check` can report what the running app last wrote.
    // Everything about this feature is otherwise invisible from outside the process: the throttle
    // means a second launch does nothing, and there's no UI at all when you're up to date.

    nonisolated static var lastCheck: Date? {
        UserDefaults.standard.object(forKey: Key.lastCheck) as? Date
    }

    nonisolated static var cachedRelease: Release? {
        let defaults = UserDefaults.standard
        guard let version = defaults.string(forKey: Key.latestVersion),
              let page = defaults.string(forKey: Key.latestPage).flatMap(URL.init(string:))
        else { return nil }
        return Release(version: version, page: page)
    }

    // MARK: - Getting the update

    /// The other way in. Which one a given copy used isn't knowable from inside the app — a
    /// cask-installed bundle sits at exactly the same `/Applications` path as a hand-dragged
    /// one — so both routes are offered wherever the notice appears, rather than guessed at.
    nonisolated static let brewCommand = "brew upgrade --cask your-turn"

    nonisolated static func copyBrewCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(brewCommand, forType: .string)
    }

    // MARK: - The request

    nonisolated static let latestReleaseAPI = URL(
        string: "https://api.github.com/repos/himynameisben/your-turn/releases/latest"
    )!

    /// Named cases rather than a bare `nil` so `--update-check` can say which of these it hit.
    /// Measured its worth immediately: a sandbox silently refusing `api.github.com` and a bug in
    /// the parsing look identical from the outside.
    enum FetchFailure: Error, Equatable {
        case transport(String)
        case status(Int)
        case malformed
    }

    /// `/releases/latest` rather than the tag or release list: it already excludes drafts and
    /// prereleases, so a release that isn't published yet can't advertise itself to anyone.
    ///
    /// The app's second and last outbound request, and like the price table it carries nothing
    /// about the user — a bare GET to a public endpoint. Failure is not an error state: the
    /// notice simply doesn't appear.
    nonisolated static func fetchLatest() async -> Result<Release, FetchFailure> {
        var request = URLRequest(url: latestReleaseAPI)
        request.timeoutInterval = 15
        // GitHub's API rejects a request with no User-Agent outright. URLSession supplies a
        // default one, but naming the app makes the entry in GitHub's logs honest.
        request.setValue("YourTurn", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return .failure(.transport(error.localizedDescription))
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { return .failure(.status(status)) }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:))
        else { return .failure(.malformed) }

        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return version.isEmpty ? .failure(.malformed) : .success(Release(version: version, page: page))
    }

    // MARK: - Versions

    /// The running bundle's `CFBundleShortVersionString`, which `bundle.sh` and `release.sh`
    /// both stamp in.
    ///
    /// A bare `swift build` binary has no Info.plist at all — that's how `--render` runs — so
    /// there is nothing to compare and the check is skipped rather than guessed at.
    nonisolated static var currentVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// Compares dotted versions component by component.
    ///
    /// String comparison breaks the first time a component reaches double digits: "0.10.0"
    /// sorts *before* "0.9.0", so the app would go quiet exactly when it finally had something
    /// to say. Missing components read as 0, so "0.3" and "0.3.0" are the same release.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let new = components(candidate), old = components(current)
        for index in 0..<max(new.count, old.count) {
            let lhs = index < new.count ? new[index] : 0
            let rhs = index < old.count ? old[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    /// `prefix(while:)` rather than a plain `Int(...)` so a suffixed component ("1.2.0-beta")
    /// still yields its number instead of collapsing the whole comparison to zero.
    private nonisolated static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }
}

// MARK: - Verification entry point

extension UpdateCheck {
    /// `--update-check`: prints the running version, what GitHub reports, the verdict, and the
    /// ordering table.
    ///
    /// Always fetches, ignoring the daily throttle — that throttle is precisely what makes this
    /// behaviour impossible to observe on demand from the UI. English, like the rest of the CLI
    /// output: these are developer tools, not product surfaces.
    nonisolated static func cli() {
        print("current: \(currentVersion ?? "(none — a bare swift build binary has no Info.plist)")")
        // What the *app* last wrote, not what this invocation is about to fetch — the only
        // window onto whether the launch-time check actually ran and persisted anything.
        if let last = lastCheck {
            // Resolved the same way a launching app resolves it, so seeding the two cached keys
            // is enough to exercise the notice without waiting for a release that doesn't exist.
            let resolved = cachedRelease.map { release in
                currentVersion.map { isNewer(release.version, than: $0) ? "shows the notice" : "quiet" }
                    ?? "no version to compare"
            } ?? "nothing"
            print("stored:  \(cachedRelease.map(\.version) ?? "nothing"),"
                  + " checked \(Int(Date().timeIntervalSince(last)))s ago → \(resolved)")
        } else {
            print("stored:  never checked")
        }

        // Safe to block: `fetchLatest()` is nonisolated (it's a URLSession call), so nothing
        // here is waiting on the main actor the way `--render`'s run-loop pump has to.
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box()
        Task {
            box.value = await fetchLatest()
            semaphore.signal()
        }
        semaphore.wait()

        switch box.value {
        case .success(let release):
            print("latest:  \(release.version)")
            print("page:    \(release.page.absoluteString)")
            if let current = currentVersion {
                print("verdict: \(isNewer(release.version, than: current) ? "update available" : "up to date")")
            } else {
                print("verdict: skipped, nothing to compare against")
            }
        case .failure(.transport(let message)):
            print("latest:  request failed — \(message)")
        case .failure(.status(let code)):
            print("latest:  HTTP \(code) — rate-limited, or no release published yet")
        case .failure(.malformed), .none:
            print("latest:  response had no usable tag_name/html_url")
        }

        // The live check above can only ever exercise one pair of versions — whatever happens to
        // be published today. This is the rest of the ordering, including the case that makes
        // string comparison wrong, which no release can demonstrate until 0.10.0 actually ships.
        print("\nordering")
        let pairs = [("0.3.0", "0.2.0"), ("0.2.0", "0.3.0"), ("0.2.0", "0.2.0"),
                     ("0.10.0", "0.9.0"), ("0.9.0", "0.10.0"),
                     ("1.0", "1.0.0"), ("0.2.1", "0.2"), ("1.0.0", "0.9.9")]
        for (candidate, current) in pairs {
            let verdict = isNewer(candidate, than: current) ? "newer" : "not newer"
            let asStrings = candidate > current ? "newer" : "not newer"
            let flag = verdict == asStrings ? "" : "   ← string comparison disagrees"
            print("  \(candidate.padding(toLength: 7, withPad: " ", startingAt: 0))"
                  + "vs \(current.padding(toLength: 8, withPad: " ", startingAt: 0))\(verdict)\(flag)")
        }
    }

    private final class Box: @unchecked Sendable {
        var value: Result<Release, FetchFailure>?
    }
}
