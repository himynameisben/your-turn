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
        // The session-list frames draw the masthead's allowance rings, so they need a reading —
        // and only a reading. Under --demo it's invented, for the same reason the sessions are:
        // a published screenshot must not say how much of a real week is already spent.
        let sessionStats = StatsStore()
        let preferences = AppPreferences()
        let updates = UpdateCheck()
        /// A second, deliberately empty one for the pages that get published.
        let quiet = UpdateCheck()

        if demo {
            store.loadDemo(DemoData.groups(now: Date()))
            sessionStats.loadDemoQuotas(DemoData.quotas(now: Date()))
            // A real render is quiet here — the copy being rendered is the current one — so the
            // update notice's layout only exists to look at under --demo.
            updates.loadDemo(
                UpdateCheck.Release(
                    version: "0.3.0",
                    page: URL(string: "https://github.com/himynameisben/your-turn/releases/latest")!
                )
            )
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
            sessionStats.loadDemoQuotas(
                ClaudeQuotaReader.read() + CodexQuotaReader.read(sessions: store.sessions)
            )
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
                // Allowance rings only. A full StatsStore here would drag the 1.0GB usage scan
                // into every session screenshot.
                stats: sessionStats,
                preferences: preferences,
                // Quiet on purpose, even under --demo: these are the shots that get published,
                // and an "Update" badge in the README implies the app in the picture is stale.
                // The badge and its sheet get their own files below.
                updates: quiet,
                mode: .constant(.byProject),
                query: .constant(""),
                now: Date(),
                showingUpdate: .constant(false)
            )
            .frame(width: 1000, alignment: .topLeading)
            .themed(appearance)
            .environment(\.isOffscreenRender, true)
            .background(palette.bg)

            write(view, to: outputDirectory.appendingPathComponent("\(appearance.rawValue).png"))

            preferences.appearance = appearance
            // Through `MainWindowPage` with the mode pinned, same as the usage tab: settings is a
            // tab now, so a frame of `SettingsPage` on its own would leave out the masthead and
            // the picker that are half of what changed.
            //
            // This is the one page rendered with a live `updates`: the About row's badge is
            // otherwise unrenderable, and these frames aren't published — see `docs/RELEASING`.
            let settings = MainWindowPage(
                store: store,
                stats: StatsStore(),
                preferences: preferences,
                updates: updates,
                mode: .constant(.settings),
                query: .constant(""),
                now: Date(),
                showingUpdate: .constant(false)
            )
            .frame(width: 1000, alignment: .topLeading)
            .themed(appearance)
            .environment(\.isOffscreenRender, true)
            .background(palette.bg)
            write(settings, to: outputDirectory.appendingPathComponent("\(appearance.rawValue)-settings.png"))
        }
        // One frame at the window's 720pt minimum, with everything the masthead can hold up at
        // once: the update badge, the search field, and all four tab pills. That right-hand
        // cluster only grew — the gear button left, but a fourth pill costs more than it freed —
        // and the headline is what has to give way, so this is the frame that proves it does.
        let narrow = MainWindowPage(
            store: store,
            stats: sessionStats,
            preferences: preferences,
            updates: updates,
            mode: .constant(.byProject),
            query: .constant(""),
            now: Date(),
            showingUpdate: .constant(false)
        )
        .frame(width: 720, alignment: .topLeading)
        .themed(.light)
        .environment(\.isOffscreenRender, true)
        .background(Theme.paper.bg)
        write(narrow, to: outputDirectory.appendingPathComponent("light-narrow.png"))

        // The masthead before anyone has switched the bridge on — a dashed ring where a reading
        // would be. Same reasoning as `light-usage-month.png` and the update badge: it's a state
        // that only exists before a setting is touched, so no screenshot of the default demo
        // would ever contain it, and it's the first thing a new user actually sees.
        let unset = StatsStore()
        unset.loadDemoQuotas(DemoData.quotas(now: Date()).filter { $0.agent != .claude })
        let setup = MainWindowPage(
            store: store,
            stats: unset,
            preferences: preferences,
            updates: quiet,
            mode: .constant(.byProject),
            query: .constant(""),
            now: Date(),
            showingUpdate: .constant(false)
        )
        .frame(width: 1000, alignment: .topLeading)
        .themed(.light)
        .environment(\.isOffscreenRender, true)
        .background(Theme.paper.bg)
        write(setup, to: outputDirectory.appendingPathComponent("light-allowance-setup.png"))

        // Resting above, hovered below, same width, same everything else. The rings have to sit at
        // the same x in both — the first version of this row put the detail *before* them, so
        // arriving with the cursor pushed them right, out from under it, which ended the hover and
        // pushed them back. That loop ran at refresh rate and repainted the whole page each time.
        // A frame of the resting state alone could never have shown it.
        let quotas = DemoData.quotas(now: Date())
        let hover = VStack(alignment: .leading, spacing: 26) {
            MastheadKicker(dateline: "August 17 · Monday", quotas: quotas, now: Date()) { _ in }
            MastheadKicker(
                dateline: "August 17 · Monday", quotas: quotas, now: Date(), onSelect: { _ in },
                initialHover: .quota(quotas[1])
            )
        }
        .padding(.horizontal, Theme.pageInset)
        .padding(.vertical, 24)
        .frame(width: 720, alignment: .topLeading)
        .themed(.light)
        .environment(\.isOffscreenRender, true)
        .background(Theme.paper.bg)
        write(hover, to: outputDirectory.appendingPathComponent("light-allowance-hover.png"))

        renderStats(
            to: outputDirectory, demo: demo, store: store, preferences: preferences, quiet: quiet
        )
        renderUpdate(
            to: outputDirectory, updates: updates, preferences: preferences,
            store: store, stats: sessionStats
        )
    }

    /// The update sheet, plus one frame of the masthead carrying its badge.
    ///
    /// Same reasoning as `light-usage-month.png`: these are states that exist only after a
    /// release lands, so nothing in a default render shows them. The sheet gets all three
    /// palettes — it has a filled primary button and a bordered code box, and both need looking
    /// at on warm black — while the badge-in-context frame is light only, since what's being
    /// checked there is alignment against the gear button and the tab picker.
    private static func renderUpdate(
        to directory: URL, updates: UpdateCheck, preferences: AppPreferences,
        store: SessionStore, stats: StatsStore
    ) {
        guard case .available(let release) = updates.state else {
            print("Update: nothing pending, skipping the update frames")
            return
        }
        for appearance in Appearance.allCases where appearance != .system {
            let palette = appearance.theme(system: .light)
            let sheet = UpdateSheet(release: release)
                .themed(appearance)
                .environment(\.isOffscreenRender, true)
                .background(palette.bg)
            write(sheet, to: directory.appendingPathComponent("\(appearance.rawValue)-update.png"))
        }

        let badged = MainWindowPage(
            store: store,
            stats: stats,
            preferences: preferences,
            updates: updates,
            mode: .constant(.byProject),
            query: .constant(""),
            now: Date(),
            showingUpdate: .constant(false)
        )
        .frame(width: 1000, alignment: .topLeading)
        .themed(.light)
        .environment(\.isOffscreenRender, true)
        .background(Theme.paper.bg)
        write(badged, to: directory.appendingPathComponent("light-update-badge.png"))

        // The menu bar panel is otherwise never rendered — its list is a `ScrollView`, which
        // `ImageRenderer` won't expand, so the frame comes out with an empty middle. That's fine
        // here: what's being checked is the footer, where the badge has to sit beside "All"
        // without pushing the "…" button off the panel's fixed 390pt.
        let panel = MenuBarPanel(
            store: store, preferences: preferences, navigation: Navigation(), updates: updates
        )
        .themed(.light)
        .environment(\.isOffscreenRender, true)
        .background(Theme.paper.bg)
        write(panel, to: directory.appendingPathComponent("light-update-panel.png"))
    }

    /// Renders the usage tab for each palette.
    ///
    /// Renders `MainWindowPage` with the mode pinned rather than some usage-only view, so
    /// what lands in the PNG is literally the page the user sees, masthead and tab picker
    /// included. A real scan here would publish this machine's project names and actual
    /// spend, so `--demo` is not optional for anything that leaves the laptop.
    private static func renderStats(
        to directory: URL, demo: Bool, store: SessionStore, preferences: AppPreferences,
        quiet: UpdateCheck
    ) {
        let stats = usageStore(demo: demo, period: .all)
        print("Usage: \(stats.summary?.requests ?? 0) request(s)")

        for appearance in Appearance.allCases where appearance != .system {
            let palette = appearance.theme(system: .light)
            let page = MainWindowPage(
                store: store,
                stats: stats,
                preferences: preferences,
                updates: quiet,
                mode: .constant(.usage),
                query: .constant(""),
                now: Date(),
                showingUpdate: .constant(false)
            )
            .frame(width: 1000, alignment: .topLeading)
            .themed(appearance)
            .environment(\.isOffscreenRender, true)
            .background(palette.bg)
            write(page, to: directory.appendingPathComponent("\(appearance.rawValue)-usage.png"))
        }

        // The same page at the window's 720pt minimum, for the same reason `light-narrow.png`
        // exists one page over. The allowance row is the one here that can't simply wrap: a
        // fixed label, a bar, a percentage and a reset time on one line, and the reset time grew
        // from a countdown ("in 1d") to a wall clock ("Aug 19 at 8:00 AM"). Whether that still
        // fits is a question only this frame answers.
        let narrow = MainWindowPage(
            store: store,
            stats: stats,
            preferences: preferences,
            updates: quiet,
            mode: .constant(.usage),
            query: .constant(""),
            now: Date(),
            showingUpdate: .constant(false)
        )
        .frame(width: 720, alignment: .topLeading)
        .themed(.light)
        .environment(\.isOffscreenRender, true)
        .background(Theme.paper.bg)
        write(narrow, to: directory.appendingPathComponent("light-usage-narrow.png"))

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
            updates: quiet,
            mode: .constant(.usage),
            query: .constant(""),
            now: Date(),
            showingUpdate: .constant(false)
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
            stats.loadDemo(DemoData.usage(now: Date()), quotas: DemoData.quotas(now: Date()))
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
    /// Invented, like everything else here — a real reading would publish how much of someone's
    /// actual allowance they've burned this week.
    ///
    /// All three rows, and one of them below the 20% line, because the amber bar is a state a
    /// screenshot of a comfortable week would never show.
    static func quotas(now: Date) -> [AgentQuota] {
        [
            AgentQuota(
                agent: .claude, usedPercent: 38, windowMinutes: 5 * 60,
                resetsAt: now.addingTimeInterval(2.4 * 3600),
                observedAt: now.addingTimeInterval(-4 * 60)
            ),
            AgentQuota(
                agent: .claude, usedPercent: 84, windowMinutes: 7 * 24 * 60,
                resetsAt: now.addingTimeInterval(1.6 * 86_400),
                observedAt: now.addingTimeInterval(-4 * 60)
            ),
            // Deliberately stale enough to earn the "measured …" half of the footnote: that is
            // the long variant of the row, and the one the 720pt frame has to prove still fits.
            AgentQuota(
                agent: .codex, usedPercent: 46, windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(3.2 * 86_400),
                observedAt: now.addingTimeInterval(-3.4 * 3600)
            ),
        ]
    }

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
                // The one Codex row, and it sits in a project that also has a Claude one —
                // which is the only arrangement that shows what the badge is for. `live` is
                // nil rather than `.idle`: Codex reports no status, so a demo that gave it one
                // would picture a state the real app can never reach.
                item(
                    title: "Port the search index to the new schema",
                    you: "Move the search index over to the v2 schema and keep the old one readable",
                    claude: """
                        The v2 writer is in and both readers pass the fixture suite. The old index \
                        is still on disk untouched, so nothing is lost if this needs backing out.
                        """,
                    minutesAgo: 12,
                    state: .awaiting,
                    live: nil,
                    now: now,
                    agent: .codex
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
        now: Date,
        agent: Agent = .claude
    ) -> Row {
        { path in
            ResolvedSession(
                session: Session(
                    id: UUID().uuidString,
                    agent: agent,
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
                live: live,
                exactMatch: live != nil
            )
        }
    }
}
