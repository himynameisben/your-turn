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
