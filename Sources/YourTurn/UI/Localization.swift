import Foundation
import SwiftUI

/// Every user-visible string goes through here. Keys are the English text itself, so the
/// English build reads correctly even if a lookup ever misses.
///
/// Why a helper rather than SwiftUI's `Text("literal")`: that resolves against `Bundle.main`,
/// but a SwiftPM target's resources land in `Bundle.module` — every string would silently
/// render as its own English key. One function keeps `Text`, `Button`, `.help` and plain
/// `String` values (headline, tooltips, relative time) on the same path.
///
/// CLI output (`--dump` / `--triage` / `--next` / `--render` progress lines) deliberately does
/// **not** go through here: it's a developer verification tool, and English keeps its column
/// widths and grep-ability stable.
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: Localization.bundle)
}

/// The language setting. Its `rawValue` is the `.lproj` name, so what lands in UserDefaults
/// is the BCP-47 tag itself and no separate mapping table has to be kept in sync.
///
/// Lives here rather than next to `Appearance` because the two named cases only exist as long
/// as `Resources/<tag>.lproj` does — adding a third translation means editing this enum and
/// nothing else.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case traditionalChinese = "zh-Hant"

    var id: String { rawValue }

    /// nil = follow `Locale.preferredLanguages`.
    var identifier: String? { self == .system ? nil : rawValue }

    /// The two real languages name themselves instead of being translated. A language menu is
    /// the one menu a user reads while the UI is in a language they can't read — "Traditional
    /// Chinese" spelled in English helps nobody looking for 繁體中文.
    var displayName: String {
        switch self {
        case .system: L("Follow System")
        case .english: "English"
        case .traditionalChinese: "繁體中文"
        }
    }
}

enum Localization {
    /// The user's explicit choice; `.system` follows `Locale.preferredLanguages`. Written by
    /// `AppPreferences` — at launch and whenever the settings picker moves.
    ///
    /// `nonisolated(unsafe)`: writes only ever come from the main actor, but reads come from
    /// the scanner's `concurrentPerform` threads too (`Session.displayTitle`,
    /// `ProcessProbe.displayName`). Same trade-off as `JSONLTailReader`'s shared formatters —
    /// and the worst a racing read could do is label one string in the previous language for
    /// one frame, which the rebuild below immediately paints over.
    nonisolated(unsafe) static var override: AppLanguage = .system {
        didSet { state = Resolution(override) }
    }

    nonisolated(unsafe) private static var state = Resolution(.system)

    /// The single `.lproj` inside `Bundle.module` that `L(…)` reads from.
    static var bundle: Bundle { state.bundle }

    /// Locale for date formatting — tied to the language the UI actually resolved to, not to
    /// `Locale.current`. A French system reads English text; pairing that with French weekday
    /// names would look like a bug rather than a fallback.
    static var locale: Locale { state.locale }

    /// Which translation the UI actually landed on — never `.system`. The settings note uses it
    /// to spell out what "Follow System" currently resolves to.
    static var resolved: AppLanguage { state.language }

    private struct Resolution {
        let bundle: Bundle
        let locale: Locale
        let language: AppLanguage

        /// Matched against the available localizations by hand instead of just handing
        /// `Bundle.module` to `String(localized:)`. Measured: CFBundle clamps every sub-bundle to
        /// the localizations the **main** bundle declares, and a bare `swift build` binary declares
        /// none — so `Bundle.module` returns English no matter what, and `--render` could never
        /// produce a Chinese screenshot. Doing the match ourselves behaves identically inside the
        /// .app and from the raw binary, and it's also the only way an in-app override can work at
        /// all: CFBundle reads the system's language list, not ours.
        ///
        /// Resolution is checked, not assumed: `zh-TW`, `zh-Hant-TW` and `zh-Hant` all land on
        /// zh-Hant; `fr` falls back to `en`.
        init(_ override: AppLanguage) {
            let wanted = override.identifier.map { [$0] } ?? Locale.preferredLanguages
            // The name has to come back from `preferredLocalizations` rather than be spelled out:
            // SwiftPM copies `zh-Hant.lproj` into the resource bundle lowercased as `zh-hant.lproj`.
            let name = Bundle.preferredLocalizations(
                from: Bundle.module.localizations, forPreferences: wanted
            ).first ?? "en"

            bundle = Bundle.module.path(forResource: name, ofType: "lproj")
                .flatMap(Bundle.init(path:)) ?? .module
            locale = Locale(identifier: name)
            language = name.hasPrefix("zh") ? .traditionalChinese : .english
        }
    }
}

/// Rebuilds its content whenever the language preference changes. Applied at the root of all
/// three scenes, so the menu bar panel, the main window and the settings window turn over
/// together instead of one at a time.
///
/// Why identity and not the environment: `L()` is a plain function, so no view holds a
/// dependency on the language — flipping it would leave every already-rendered string exactly
/// where it was until something else happened to invalidate that view. Reading
/// `preferences.language` here (an `@Observable` property) is what makes SwiftUI notice at all,
/// and changing the subtree's id is the one lever that re-runs every `body` underneath.
///
/// The cost is that `@State` below the scope resets — the main window's search field and
/// by-time/by-project pick go back to defaults. Accepted: this is a setting you touch once.
private struct LanguageScope<Content: View>: View {
    let preferences: AppPreferences
    let content: Content

    var body: some View {
        content.id(preferences.language)
    }
}

extension View {
    func localized(_ preferences: AppPreferences) -> some View {
        LanguageScope(preferences: preferences, content: self)
    }
}
