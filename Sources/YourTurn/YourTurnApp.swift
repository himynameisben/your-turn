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

    @State private var store = SessionStore()
    @State private var preferences = AppPreferences()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(store: store, preferences: preferences)
                .themed(preferences.appearance)
                .localized(preferences)
        } label: {
            // Only counting "waiting for you" — running sessions don't need you yet, and finished ones aren't urgent.
            // The menu bar icon must be a monochrome template image; the system handles light/dark automatically.
            Image(systemName: store.badgeCount > 0 ? "tray.full" : "tray")
            if store.badgeCount > 0 {
                Text("\(store.badgeCount)")
            }
        }
        .menuBarExtraStyle(.window)

        Window("Your Turn", id: MainWindow.id) {
            MainWindow(store: store, preferences: preferences)
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
            SettingsWindow(store: store, preferences: preferences)
                .themed(preferences.appearance)
                .localized(preferences)
                .managesActivationPolicy()
        }
        .windowResizability(.contentSize)
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
