import SwiftUI

@main
struct YourTurnApp: App {
    init() {
        // Data-layer verification entry point: exits before any scene is created, so no UI flashes.
        if CommandLine.arguments.contains("--dump") {
            DumpCommand.run()
            exit(0)
        }
        if CommandLine.arguments.contains("--triage") {
            DumpCommand.triage()
            exit(0)
        }
        if CommandLine.arguments.contains("--next") {
            DumpCommand.verifyNextActions()
            exit(0)
        }
        // Usage/cost verification entry point. `--no-cache` forces a cold scan, which is the
        // only way to compare the two paths' numbers and timings against each other.
        if CommandLine.arguments.contains("--cost") {
            CostCommand.run(
                useCache: !CommandLine.arguments.contains("--no-cache"),
                refreshPrices: CommandLine.arguments.contains("--refresh-prices")
            )
            exit(0)
        }
        // Update-check verification entry point. Only meaningful from the binary inside the
        // .app: a bare `swift build` binary has no version to compare GitHub's answer against.
        if CommandLine.arguments.contains("--update-check") {
            UpdateCheck.cli()
            exit(0)
        }
        // Login-item verification entry point. Only meaningful from the binary inside the
        // .app — SMAppService answers for the bundle it's running in.
        if let index = CommandLine.arguments.firstIndex(of: "--login-item") {
            let next = CommandLine.arguments.count > index + 1
                ? CommandLine.arguments[index + 1] : nil
            MainActor.assumeIsolated { LaunchAtLogin.cli(next) }
            exit(0)
        }
        // Layout verification entry point: offscreen-renders the main window PNG for each palette.
        if let index = CommandLine.arguments.firstIndex(of: "--render") {
            // The argument after --render is the directory unless it's the next flag, so
            // `--render --demo` still lands in the current directory instead of a folder
            // literally named "--demo".
            let next = CommandLine.arguments.count > index + 1
                ? CommandLine.arguments[index + 1] : nil
            let directory = next.flatMap { $0.hasPrefix("--") ? nil : $0 }
                ?? FileManager.default.currentDirectoryPath
            // --demo renders invented sessions: screenshots of a real scan would publish
            // whatever that machine happened to be working on.
            let demo = CommandLine.arguments.contains("--demo")
            MainActor.assumeIsolated { RenderCommand.run(to: directory, demo: demo) }
            exit(0)
        }
    }

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    @State private var store = SessionStore()
    @State private var stats = StatsStore()
    @State private var preferences = AppPreferences()
    @State private var navigation = Navigation()
    @State private var updates = UpdateCheck()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(
                store: store, preferences: preferences, navigation: navigation, updates: updates
            )
            .themed(preferences.appearance)
            .localized(preferences)
        } label: {
            MenuBarLabel(badgeCount: store.badgeCount, updates: updates)
        }
        .menuBarExtraStyle(.window)

        Window("Your Turn", id: MainWindow.id) {
            MainWindow(store: store, stats: stats, preferences: preferences, navigation: navigation)
                .themed(preferences.appearance)
                .localized(preferences)
                // Outside `.localized`, deliberately: a language switch rebuilds everything
                // inside that scope, and the open/close counter must not see the teardown as
                // "the last window closed" and drop the app back to `.accessory` — that would
                // send both windows behind whatever else is on screen mid-switch.
                .managesActivationPolicy()
        }
        .defaultSize(width: 860, height: 660)
        .commands {
            // Replaces the system's default "Settings…" item so Cmd-, opens our own settings window.
            CommandGroup(replacing: .appSettings) {
                SettingsCommandButton()
            }
        }

        Window(L("Settings"), id: SettingsWindow.id) {
            SettingsWindow(store: store, preferences: preferences, updates: updates)
                .themed(preferences.appearance)
                .localized(preferences)
                .managesActivationPolicy()
        }
        .windowResizability(.contentSize)
    }
}

/// Clicking a Dock icon has to open the inbox.
///
/// `LSUIElement` means this app has no Dock icon of its own — one only appears while a window
/// is open, because `managesActivationPolicy()` flips the activation policy to `.regular` for
/// as long as that lasts. Anyone who then picks "Keep in Dock" ends up with a permanent icon
/// for an app that usually has no windows at all, and macOS's default answer to clicking it
/// is to do nothing: the app is already running, so there is nothing to launch.
/// `applicationShouldHandleReopen` is the only hook that fires in that case.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Installed by the menu bar's label, which is the one piece of UI that exists for the
    /// app's entire lifetime — both windows can be closed, and the panel is only built when
    /// the menu is actually opened.
    static var openInbox: (() -> Void)?

    private static var hasOpenedOnLaunch = false

    /// True exactly once per process, so "open the window when the app starts" can't turn
    /// into "open the window again whenever the menu bar badge changes" — the label this is
    /// called from re-evaluates its body on every scan.
    static func claimLaunchWindow() -> Bool {
        guard !hasOpenedOnLaunch else { return false }
        hasOpenedOnLaunch = true
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // With a window already up, macOS brings it forward by itself.
        guard !hasVisibleWindows else { return true }
        Self.openInbox?()
        return true
    }
}

/// The menu bar icon.
///
/// A view rather than a bare `Image` so it has somewhere to hand the delegate a way back into
/// the inbox — see `AppDelegate`.
private struct MenuBarLabel: View {
    /// Only counts "waiting for you": running sessions don't need you yet, and finished ones
    /// aren't urgent.
    let badgeCount: Int
    let updates: UpdateCheck

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // The menu bar icon must be a monochrome template image; the system handles
        // light/dark automatically.
        // The icon and its badge answer one question — how many sessions are waiting for you.
        // A pending update deliberately doesn't touch either: a second meaning would make the
        // number something you have to stop and interpret. It surfaces in the "…" menu instead.
        // Verified against a real reopen: the label's `onAppear` does fire once, at launch,
        // before any window exists — which is what makes this a usable registration point,
        // and the only place `openWindow` can be reached from this early.
        Image(systemName: badgeCount > 0 ? "tray.full" : "tray")
            .onAppear {
                AppDelegate.openInbox = { openWindow(id: MainWindow.id) }
                // Checked from here for the same reason the launch window is: this label is
                // the one piece of UI alive for the whole session. `UpdateCheck` carries its
                // own per-launch latch, so a re-fired `onAppear` costs nothing.
                Task { await updates.checkIfNeeded() }
                // Every launch opens the window, login included. The alternative — a window
                // on a click but not at login — needs the app to tell those apart, and macOS
                // only offers `NSApplicationLaunchIsDefaultLaunchKey` for that, whose login
                // half can't be reproduced without a real logout. One rule that always holds
                // beats a rule that's right most of the time and unverifiable the rest.
                if AppDelegate.claimLaunchWindow() { openWindow(id: MainWindow.id) }
            }
        if badgeCount > 0 {
            Text("\(badgeCount)")
        }
    }
}

/// Split into its own view so it can use `@Environment(\.openWindow)` — the `commands`
/// builder itself isn't a view environment, so reading environment values directly inside it
/// doesn't work.
private struct SettingsCommandButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L("Settings…")) { openWindow(id: SettingsWindow.id) }
            .keyboardShortcut(",", modifiers: .command)
    }
}
