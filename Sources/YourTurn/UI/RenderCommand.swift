import AppKit
import SwiftUI

/// Dev tool: offscreen-renders the main window into a PNG.
///
/// An `LSUIElement` app's windows can't be reliably captured with `screencapture` (the
/// window isn't guaranteed to be presented, and System Events needs accessibility
/// permissions), so this goes through `ImageRenderer` instead: no window opens, no
/// permissions needed — the view tree is rendered straight to a bitmap, so colors and
/// layout can actually be inspected.
///
/// Usage: `YourTurn --render <output directory> [--demo]`
///
/// `--demo` renders handcrafted sessions instead of the real scan — required for anything
/// published (README, release notes), since a real scan puts the titles, prompts and
/// summaries of whoever ran it into the picture.
@MainActor
enum RenderCommand {
    static func run(to directory: String, demo: Bool = false) {
        let store = SessionStore()
        let preferences = AppPreferences()

        if demo {
            store.loadDemo(DemoData.groups(now: Date()))
            print("Demo data: \(store.groups.count) project(s), \(store.active.count) active session(s)")
        } else {
            // ImageRenderer won't wait for `.task`, so the data scan has to finish first, manually.
            // Can't block the main thread with a semaphore — `refresh()` is @MainActor, so blocking
            // the main thread means its continuation can never return, which deadlocks.
            var done = false
            Task { await store.refresh(); done = true }
            while !done {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            print("Scanned \(store.groups.count) project(s), \(store.active.count) active session(s)")
        }

        // The settings page's pills bind to the live preference, so each palette's shot has
        // to actually select that palette — otherwise all three show "Follow System"
        // highlighted next to colors that contradict it. Put back before returning:
        // rendering a screenshot must not leave the user's setting changed.
        let savedAppearance = preferences.appearance
        defer { preferences.appearance = savedAppearance }

        let outputDirectory = URL(fileURLWithPath: directory)
        for appearance in Appearance.allCases where appearance != .system {
            // Only rendering the three non-.system palettes, so whatever is passed to `system:` doesn't affect the result.
            let palette = appearance.theme(system: .light)
            let view = MainWindowPage(
                store: store,
                // The session pages never read it; a blank store keeps the scan out of the
                // session screenshots entirely.
                stats: StatsStore(),
                preferences: preferences,
                mode: .constant(.byProject),
                query: .constant(""),
                now: Date()
            )
            .frame(width: 1000, alignment: .topLeading)
            .themed(appearance)
            .environment(\.isOffscreenRender, true)
            .background(palette.bg)

            write(view, to: outputDirectory.appendingPathComponent("\(appearance.rawValue).png"))

            preferences.appearance = appearance
            let settings = SettingsPage(store: store, preferences: preferences)
                .frame(width: 560, alignment: .topLeading)
                .themed(appearance)
                .environment(\.isOffscreenRender, true)
                .background(palette.bg)
            write(settings, to: outputDirectory.appendingPathComponent("\(appearance.rawValue)-settings.png"))
        }
        renderStats(to: outputDirectory, demo: demo, store: store, preferences: preferences)
    }

    /// Renders the usage tab for each palette.
    ///
    /// Renders `MainWindowPage` with the mode pinned rather than some usage-only view, so
    /// what lands in the PNG is literally the page the user sees, masthead and tab picker
    /// included. A real scan here would publish this machine's project names and actual
    /// spend, so `--demo` is not optional for anything that leaves the laptop.
    private static func renderStats(
        to directory: URL, demo: Bool, store: SessionStore, preferences: AppPreferences
    ) {
        let stats = usageStore(demo: demo, period: .all)
        print("Usage: \(stats.summary?.requests ?? 0) request(s)")

        for appearance in Appearance.allCases where appearance != .system {
            let palette = appearance.theme(system: .light)
            let page = MainWindowPage(
                store: store,
                stats: stats,
                preferences: preferences,
                mode: .constant(.usage),
                query: .constant(""),
                now: Date()
            )
            .frame(width: 1000, alignment: .topLeading)
            .themed(appearance)
            .environment(\.isOffscreenRender, true)
            .background(palette.bg)
            write(page, to: directory.appendingPathComponent("\(appearance.rawValue)-usage.png"))
        }

        // One extra frame with a month selected. The filtered layout differs in three places
        // — the stepper appears, the three tiles change meaning, and the heatmap dims
        // everything outside the selection — and none of that is visible in a screenshot of
        // the default state. Light palette only: it's a verification frame, not a published one.
        //
        // A second store rather than moving this one's period: `period`'s recompute runs off
        // the main actor and `ImageRenderer` won't wait for it, so the filter has to be in
        // place before the data lands.
        let filteredStats = usageStore(demo: demo, period: UsagePeriod(mode: .month, anchor: Date()))
        let filtered = MainWindowPage(
            store: store,
            stats: filteredStats,
            preferences: preferences,
            mode: .constant(.usage),
            query: .constant(""),
            now: Date()
        )
        .frame(width: 1000, alignment: .topLeading)
        .themed(.light)
        .environment(\.isOffscreenRender, true)
        .background(Theme.paper.bg)
        write(filtered, to: directory.appendingPathComponent("light-usage-month.png"))
    }

    /// The period has to be set before the data arrives — `loadDemo` aggregates on the spot,
    /// and a later change would recompute off the main actor, which `ImageRenderer` won't
    /// wait for.
    private static func usageStore(demo: Bool, period: UsagePeriod) -> StatsStore {
        let stats = StatsStore()
        stats.period = period
        guard !demo else {
            stats.loadDemo(DemoData.usage(now: Date()))
            return stats
        }
        var done = false
        Task { await stats.load(); done = true }
        while !done {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return stats
    }

    private static func write(_ view: some View, to path: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2

        guard let cgImage = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        else {
            print("✗ \(path.lastPathComponent): render failed")
            return
        }
        do {
            try png.write(to: path)
            print("✓ \(path.lastPathComponent)")
        } catch {
            print("✗ \(path.lastPathComponent): \(error.localizedDescription)")
        }
    }
}

/// Invented sessions for `--demo`. Nothing here touches disk.
///
/// Shaped to cover what a screenshot has to prove in one frame: all three states, a
/// registry-reported `waiting` chip, a summary that extracts to a next step, one that
/// extracts to "nothing pending", and a couple of closed-terminal projects so the
/// collapsed "done for now" block appears.
///
/// The summaries are written the way `SummaryText` expects to find one — the next step in
/// a trailing "Next: …" sentence — so the demo exercises the real extraction path instead
/// of hardcoding the line the UI ends up showing.
private enum DemoData {
    static func groups(now: Date) -> [ProjectGroup] {
        [
            group("weather-cli", [
                item(
                    title: "Add a --units flag",
                    you: "Add a --units flag so I can switch between celsius and fahrenheit",
                    claude: nil,
                    minutesAgo: 0.7,
                    state: .running,
                    live: .busy,
                    now: now
                ),
                item(
                    title: "Actor-based forecast cache",
                    you: "Refactor the cache layer to use actors so the forecast fetch stops racing",
                    claude: """
                        ForecastCache is an actor now and the disk writes moved behind it, so the \
                        test that used to fail about one run in five passed 50 times straight. \
                        Next: wire the new cache into the CLI entry point and drop the old NSLock path.
                        """,
                    minutesAgo: 8,
                    state: .awaiting,
                    live: .idle,
                    now: now
                ),
            ]),
            group("recipe-box", [
                item(
                    title: "Import from the Paprika export",
                    you: "Can you pull my Paprika export into the new schema?",
                    claude: """
                        Parsed 412 recipes out of the export; 9 of them have ingredient lines the \
                        splitter can't read. Next: decide whether to skip those 9 or hand-fix them \
                        before the import runs for real.
                        """,
                    minutesAgo: 22,
                    state: .awaiting,
                    live: .waiting("skip or hand-fix 9 recipes"),
                    now: now
                ),
            ]),
            group("docs-site", [
                item(
                    title: "Fix the broken sidebar anchors",
                    you: "Every anchor in the sidebar 404s on versioned pages — find out why",
                    claude: """
                        The version prefix was getting stripped twice, so every anchor pointed at \
                        the unversioned path. Rewrote the rule and all 137 links resolve. \
                        No action pending.
                        """,
                    minutesAgo: 64,
                    state: .awaiting,
                    live: .idle,
                    now: now
                ),
            ]),
            group("budget-tracker", [
                item(
                    title: "Split the CSV importer into two passes",
                    you: "Split the importer so parsing and categorising aren't in the same loop",
                    claude: "Both passes are in and the importer runs about 4x faster on the 60k-row file.",
                    minutesAgo: 5 * 60,
                    state: .finished,
                    live: nil,
                    now: now
                ),
            ]),
            group("side-project", [
                item(
                    title: "Sketch the onboarding flow",
                    you: "What would a three-screen onboarding look like for this?",
                    claude: "Wrote up three screens with copy for each. No action pending.",
                    minutesAgo: 31 * 60,
                    state: .finished,
                    live: nil,
                    now: now
                ),
            ]),
        ]
    }

    // MARK: - Usage

    /// Invented usage for the stats page.
    ///
    /// Builds real `UsageRecord`s and hands them to the real `UsageStats.build` with the real
    /// bundled price table, rather than hand-writing the totals — same principle as the
    /// session demo running through `SummaryText`: a screenshot that bypasses the pipeline
    /// stops being evidence that the pipeline works.
    ///
    /// The sequence is seeded, so re-rendering produces the identical picture and a diff of
    /// two screenshots only shows what actually changed in the layout.
    static func usage(now: Date) -> UsageScanner.Result {
        var seed: UInt64 = 20_260_812
        func roll(_ upper: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(max(upper, 1)))
        }

        // Weighted so one project clearly leads — a flat distribution would hide whether the
        // ranked bars actually rank anything.
        let projects = [("weather-cli", 5), ("recipe-box", 3), ("docs-site", 2), ("ledger", 1)]
        let models = [("claude-opus-5", 6), ("claude-sonnet-5", 3), ("claude-fable-5", 1)]
        let weighted: [(String, String)] = projects.flatMap { project, weight in
            (0..<weight).map { _ in project }
        }.enumerated().map { index, project in
            let pool = models.flatMap { model, weight in (0..<weight).map { _ in model } }
            return (project, pool[index % pool.count])
        }

        let calendar = Calendar.current
        var scan = UsageScanner.Result()
        // 18 weeks, not 30 days: the heatmap draws a 26-week grid, and a month of data in it
        // shows neither the month labels nor what a quiet stretch looks like.
        for dayOffset in (0..<126).reversed() {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: now) else { continue }
            // Two quiet days a week, so the chart has the gaps a real month has.
            if calendar.component(.weekday, from: day) == 1, roll(3) > 0 { continue }

            let sessions = 1 + roll(3)
            for session in 0..<sessions {
                let (project, model) = weighted[roll(weighted.count)]
                let sessionId = "demo-\(dayOffset)-\(session)"
                let start = 9 + roll(10)
                for request in 0..<(8 + roll(24)) {
                    let hour = min(23, start + request / 6)
                    guard let stamp = calendar.date(
                        bySettingHour: hour, minute: roll(60), second: roll(60), of: day
                    ) else { continue }
                    // Proportions taken from the real measurement, because the whole point of
                    // the "where it goes" section is that these four buckets are wildly
                    // different sizes: cache reads run ~46x cache writes and ~185x output.
                    var tokens = TokenCounts()
                    tokens.input = 2 + roll(40)
                    tokens.output = 200 + roll(1_600)
                    tokens.cacheRead = 90_000 + roll(280_000)
                    tokens.cacheWrite5m = roll(3_000)
                    tokens.cacheWrite1h = roll(6_000)
                    scan.records.append(UsageRecord(
                        requestId: "demo-\(dayOffset)-\(session)-\(request)",
                        timestamp: stamp,
                        sessionId: sessionId,
                        projectPath: "/Users/you/code/\(project)",
                        isSubagent: roll(4) == 0,
                        segments: [UsageSegment(model: model, tokens: tokens)]
                    ))
                    // One turn per handful of requests, matching the measured ratio — a turn
                    // is one thing you asked for, not one API call.
                    if request % 6 == 5 {
                        scan.turns.append(TurnRecord(
                            sessionId: sessionId,
                            timestamp: stamp.addingTimeInterval(Double(60 + roll(400))),
                            duration: Double(240 + roll(1_600)),
                            projectPath: "/Users/you/code/\(project)"
                        ))
                    }
                }
            }
        }
        scan.records.sort { $0.timestamp < $1.timestamp }
        scan.turns.sort { $0.timestamp < $1.timestamp }
        return scan
    }

    // MARK: - Sessions

    /// `item` can't build its `Session` until it knows the project path, so it hands back a
    /// closure and the group fills the path in.
    private typealias Row = (String) -> ResolvedSession

    private static func group(_ name: String, _ rows: [Row]) -> ProjectGroup {
        let path = "/Users/you/code/\(name)"
        return ProjectGroup(path: path, sessions: rows.map { $0(path) })
    }

    private static func item(
        title: String,
        you: String,
        claude: String?,
        minutesAgo: Double,
        state: SessionState,
        live: LiveStatus?,
        now: Date
    ) -> Row {
        { path in
            ResolvedSession(
                session: Session(
                    id: UUID().uuidString,
                    fileURL: URL(fileURLWithPath: "\(path)/.demo.jsonl"),
                    projectPath: path,
                    gitBranch: "main",
                    title: title,
                    summary: claude,
                    lastPrompt: you,
                    lastActivity: now.addingTimeInterval(-minutesAgo * 60),
                    tail: state == .running ? .inProgress : .turnEnded
                ),
                state: state,
                // nil: the demo never claims a live terminal, so a stray click can't
                // AppleScript its way into a window that doesn't exist.
                process: nil,
                live: live
            )
        }
    }
}
