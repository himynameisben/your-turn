import SwiftUI

/// The full set of color palettes.
///
/// Deliberately **not** driven solely by SwiftUI's `ColorScheme` — it only has two states
/// (light/dark), and we need a third: Sand keeps the character of light mode (dark text,
/// warm paper, the same layout rhythm) while pulling the background down between cream
/// and full black. So color becomes data, passed down through the `\.theme` environment
/// value — views no longer need to branch on light/dark themselves.
///
/// All three palettes' grays carry a warm shift matching their own background's color
/// temperature — the system's `.primary` / `.secondary` are neutral grays, which look
/// muddy against a cream or off-white background.
struct Theme: Sendable, Equatable {
    let bg: Color
    let text: Color
    let muted: Color
    let faint: Color
    let rule: Color
    let hover: Color
    /// The "waiting for you" chip. A soft apricot rather than alarm red — this isn't an error, just something ready for you.
    let waitingChip: ChipTone
    let runningChip: ChipTone
    /// The inverted pill (the selected state of a segmented control)
    let inverted: ChipTone

    struct ChipTone: Sendable, Equatable {
        let bg: Color
        let fg: Color
    }
}

// MARK: - The three palettes

extension Theme {
    /// Cream — off-white paper. Background L\* ≈ 98.
    static let paper = Theme(
        bg: Color(hex: 0xFBF9F6),
        text: Color(hex: 0x1F1C18),
        muted: Color(hex: 0x847C71),
        faint: Color(hex: 0xA9A199),
        rule: Color(hex: 0xEBE6DE),
        hover: Color(hex: 0x1F1C18).opacity(0.035),
        waitingChip: ChipTone(bg: Color(hex: 0xF7E9DA), fg: Color(hex: 0x9A6634)),
        runningChip: ChipTone(bg: Color(hex: 0xE6F0DF), fg: Color(hex: 0x4F7038)),
        inverted: ChipTone(bg: Color(hex: 0x262220), fg: Color(hex: 0xFBF9F6))
    )

    /// Sand — oat-toned paper. Background L\* drops from Cream's 98 to 87 (74% of the
    /// relative luminance), but it's still dark text on a light background, so the reading
    /// rhythm is identical to Cream — just easier on the eyes.
    ///
    /// Secondary-level contrast is deliberately kept aligned with Cream (muted 3.97:1 vs.
    /// 3.92, faint 2.43:1 vs. 2.42), so the sense of hierarchy doesn't shift. Body text is
    /// 10.68:1, lower than Cream's 16.15:1 — that's intentional: the background is already
    /// softened, and pure-black body text would become the one hard edge left on the
    /// screen. 10.68 is still well above WCAG AAA's 7:1.
    static let dim = Theme(
        bg: Color(hex: 0xE0D9CB),
        text: Color(hex: 0x2B2620),
        muted: Color(hex: 0x6F675B),
        faint: Color(hex: 0x928A7D),
        rule: Color(hex: 0xCEC6B5),
        hover: Color(hex: 0x1F1C18).opacity(0.05),
        waitingChip: ChipTone(bg: Color(hex: 0xF0DCC3), fg: Color(hex: 0x8A5722)),
        runningChip: ChipTone(bg: Color(hex: 0xD7E4C9), fg: Color(hex: 0x466030)),
        inverted: ChipTone(bg: Color(hex: 0x332D26), fg: Color(hex: 0xEFE9DE))
    )

    /// Ember — warm black.
    static let ink = Theme(
        bg: Color(hex: 0x1A1816),
        text: Color(hex: 0xF2EEE7),
        muted: Color(hex: 0x9A938A),
        faint: Color(hex: 0x6E675F),
        rule: Color(hex: 0x2E2A26),
        hover: Color.white.opacity(0.04),
        waitingChip: ChipTone(bg: Color(hex: 0x3B2E23), fg: Color(hex: 0xE3AC7B)),
        runningChip: ChipTone(bg: Color(hex: 0x23331F), fg: Color(hex: 0x93C47D)),
        inverted: ChipTone(bg: Color(hex: 0xF2EEE7), fg: Color(hex: 0x1A1816))
    )
}

// MARK: - Shared across palettes

extension Theme {
    /// The status dots are shared across all three palettes: they're semantic signals
    /// (waiting for you / running), and they mean the same thing regardless of theme —
    /// changing their color with the theme would just force you to relearn them.
    static let dotWaiting = Color(hex: 0xE0873C)
    static let dotRunning = Color(hex: 0x6FA84F)

    // MARK: Typography

    /// Large title. Serif gives it the feel of something to read, not a dashboard.
    static let display = Font.system(size: 27, weight: .medium, design: .serif)
    static let projectName = Font.system(size: 12, weight: .regular)
    static let lede = Font.system(size: 15, weight: .regular)
    static let sessionTitle = Font.system(size: 13, weight: .medium)
    /// The "what's next" line. One size up from the title — the title describes what's done; this line is the reason you opened the app.
    static let action = Font.system(size: 14, weight: .regular)
    /// The last thing you said. One size down from Claude's line — background context, not an instruction.
    static let said = Font.system(size: 13, weight: .regular)
    /// The "You" / "Claude" speaker labels.
    static let speaker = Font.system(size: 10.5, weight: .medium)
    static let meta = Font.system(size: 11, weight: .regular)
    static let branch = Font.system(size: 10.5, weight: .regular, design: .monospaced)
    static let chip = Font.system(size: 10.5, weight: .medium)
}

// MARK: - Resolving a palette from preferences

extension Appearance {
    /// `.system` resolves based on the system's current light/dark state; the others map directly.
    func theme(system scheme: ColorScheme) -> Theme {
        switch self {
        case .system: scheme == .dark ? Theme.ink : Theme.paper
        case .light: Theme.paper
        case .dim: Theme.dim
        case .dark: Theme.ink
        }
    }
}

// MARK: - Environment value

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.paper
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// Attached at the outermost level of every scene. The `colorScheme` it reads comes from
/// the window (i.e., whatever `NSApp.appearance` resolves to); what it injects downward is
/// the fully resolved palette.
private struct Themed: ViewModifier {
    let appearance: Appearance
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.environment(\.theme, appearance.theme(system: scheme))
    }
}

extension View {
    func themed(_ appearance: Appearance) -> some View {
        modifier(Themed(appearance: appearance))
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
