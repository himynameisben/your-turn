import AppKit
import Foundation
import Observation

/// Appearance. Besides "follow system," offers manual options too — this app is often
/// placed side-by-side with a terminal, and plenty of people run a dark terminal while
/// keeping the system in light mode; forcing it to follow the system would be jarring.
enum Appearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    /// Light in mood, dark in brightness — dark text on warm paper, but the background
    /// sits between cream and full black.
    case dim
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: L("Follow System")
        case .light: L("Light")
        case .dim: L("Dim")
        case .dark: L("Dark")
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dim: "sun.haze"
        case .dark: "moon"
        }
    }

    /// The text shown in the menu.
    ///
    /// "Follow System" must always annotate which mode it **actually** resolves to —
    /// otherwise, when the system is in dark mode, selecting it produces no visible
    /// change at all, and the user just sees the icon change while the content stays
    /// the same, making it look broken.
    func menuLabel(systemIsDark: Bool) -> String {
        guard self == .system else { return displayName }
        return systemIsDark ? L("Follow System (currently Dark)") : L("Follow System (currently Light)")
    }

    /// nil = don't override, defer to the system.
    ///
    /// "Dim" belongs to the light family: it's dark text on a bright background, so
    /// native menus, text fields, and scrollbars should all render in light mode —
    /// otherwise you'd get the jarring mismatch of a dark menu over a cream-colored page.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light, .dim: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

@Observable
@MainActor
final class AppPreferences {
    var terminal: TerminalApp {
        didSet { defaults.set(terminal.rawValue, forKey: Key.terminal) }
    }

    var editor: EditorApp {
        didSet { defaults.set(editor.rawValue, forKey: Key.editor) }
    }

    var appearance: Appearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Key.appearance)
            applyAppearance()
        }
    }

    /// The resolution itself lives in `Localization` (it's read from background scanner
    /// threads, which an `@Observable @MainActor` object can't serve); this property is the
    /// stored preference and the thing views observe to know they must rebuild.
    var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Key.language)
            Localization.override = language
        }
    }

    /// Lives in the system's login-item database rather than UserDefaults, so it's kept
    /// as its own object instead of a stored property here.
    let launchAtLogin = LaunchAtLogin()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let terminal = "terminalApp"
        static let editor = "editorApp"
        static let appearance = "appearance"
        static let language = "language"
    }

    init() {
        let savedTerminal = defaults.string(forKey: Key.terminal).flatMap(TerminalApp.init)
        // If nothing's been set yet, pick one that's installed, so the first tap of
        // "Resume" isn't a no-op.
        terminal = savedTerminal ?? TerminalApp.allCases.first(where: \.isInstalled) ?? .terminal

        let savedEditor = defaults.string(forKey: Key.editor).flatMap(EditorApp.init)
        editor = savedEditor ?? EditorApp.allCases.first(where: \.isInstalled) ?? .vscode

        appearance = defaults.string(forKey: Key.appearance).flatMap(Appearance.init) ?? .system
        language = defaults.string(forKey: Key.language).flatMap(AppLanguage.init) ?? .system

        applyAppearance()
        // `didSet` doesn't fire from an initializer, so the override has to be pushed by hand —
        // and it has to happen here, before any scene builds, or the first frame renders in the
        // system language and only corrects itself on the next redraw.
        Localization.override = language
    }

    /// Overridden at the `NSApplication` level rather than via SwiftUI's `.preferredColorScheme`.
    /// This app has two scenes (the menu bar panel and the main window) plus native menus
    /// and window title bars — only an app-level appearance override keeps them all
    /// consistent; SwiftUI's `colorScheme` environment value follows the window's
    /// `effectiveAppearance`, so `Theme` picks up the change automatically too.
    private func applyAppearance() {
        NSApplication.shared.appearance = appearance.nsAppearance
    }

    /// The system's own light/dark setting.
    ///
    /// Deliberately reads `AppleInterfaceStyle` instead of asking SwiftUI's `colorScheme` —
    /// the latter reflects the result of our own override (e.g. it reports light when
    /// "Dim" is selected), so it can't tell us the system's actual setting.
    var systemIsDark: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    var installedTerminals: [TerminalApp] { TerminalApp.allCases.filter(\.isInstalled) }
    var installedEditors: [EditorApp] { EditorApp.allCases.filter(\.isInstalled) }
}
