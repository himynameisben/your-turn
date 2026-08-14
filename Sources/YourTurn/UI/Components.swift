import AppKit
import SwiftUI

/// Segmented control: a row of pills, the selected one highlighted.
///
/// Made generic because it's used in two places (the main window's by-time/by-project
/// toggle, and the settings page's four-way appearance picker), and because it's pure
/// SwiftUI, so offscreen rendering can see it — the native `Picker` can't.
struct PillPicker<Option: Identifiable & Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let selected = option == selection
                Text(title(option))
                    .font(Theme.meta)
                    .foregroundStyle(selected ? theme.inverted.fg : theme.muted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(selected ? theme.inverted.bg : .clear, in: .rect(cornerRadius: 6))
                    .contentShape(.rect)
                    .onTapGesture {
                        withAnimation(.snappy(duration: 0.14)) { selection = option }
                    }
            }
        }
        .padding(2)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.rule, lineWidth: 1))
        // Never compresses. Measured at the window's minimum width with four tabs: without this
        // the labels truncate to "By…", "By p…", "Us…", "Sett…" — a segmented control whose
        // segments can't be read is worse than a headline that wraps one line further, and the
        // headline is the only other thing in that row that can give.
        .fixedSize()
    }
}

/// One line of dialogue: right-aligned speaker + content. Shared by the main window
/// and the menu bar panel.
///
/// The speaker label is right-aligned within a fixed width, which is what lines up
/// the left edge of both lines into a straight line — the same trick as the
/// page-wide gutter, just scaled down a level.
///
/// `emphasized` decides who's the lead, and it's the opposite in each interface: the
/// main window's lead is the next step Claude left behind; the menu bar panel's lead
/// is your last command (the question it needs to answer at a glance is "what was I
/// just doing").
struct SpeakerLine: View {
    let speaker: String
    let text: String
    let emphasized: Bool
    var lineLimit = 2

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(speaker)
                .font(Theme.speaker)
                .foregroundStyle(theme.faint)
                .frame(width: 36, alignment: .trailing)
            Text(text)
                .font(emphasized ? Theme.action : Theme.said)
                .foregroundStyle(emphasized ? theme.text : theme.muted)
                .lineSpacing(3)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Number badge next to the project name. Replaces the old "N waiting" text chip —
/// that phrase took up a whole line per project, when only the number ever changed.
struct CountBadge: View {
    let count: Int
    let tone: Theme.ChipTone

    var body: some View {
        Text("\(count)")
            .font(Theme.chip)
            .foregroundStyle(tone.fg)
            .frame(minWidth: 17, minHeight: 17)
            .background(tone.bg, in: .capsule)
    }
}

/// An `LSUIElement` app's windows open behind other apps by default, and can't be
/// switched to with Cmd-Tab. While a window is open, temporarily flip the activation
/// policy to `.regular`, then flip it back to `.accessory` once everything's closed.
///
/// Uses a counter instead of each window setting/unsetting on its own: otherwise,
/// with the main window and settings window both open, closing one would demote the
/// other — still open — back to the background too.
@MainActor
private enum ActivationPolicy {
    private static var openWindows = 0

    static func windowOpened() {
        openWindows += 1
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    static func windowClosed() {
        openWindows = max(0, openWindows - 1)
        if openWindows == 0 { NSApp.setActivationPolicy(.accessory) }
    }
}

extension View {
    func managesActivationPolicy() -> some View {
        onAppear { ActivationPolicy.windowOpened() }
            .onDisappear { ActivationPolicy.windowClosed() }
    }

    func allowsFullScreen() -> some View { background(FullScreenEnabler()) }
}

/// `LSUIElement` costs the window its green button, and no SwiftUI modifier gives it back.
///
/// Measured on the real window: `collectionBehavior` settles at 131328 — `.auxiliary` plus
/// `.fullScreenAuxiliary`, with no `.fullScreenPrimary`. AppKit stamps that on every window an
/// `LSUIElement` app opens. An auxiliary window may *join* another app's full-screen space but
/// can't own one, so the green button is left with plain zoom (measured: it does fill the
/// visible frame, the screen minus the menu bar) and there's no "Enter Full Screen" anywhere.
///
/// Two things it is *not*, both measured before settling on this: it isn't the activation
/// policy at the moment the window is born — promoting to `.regular` before `openWindow` gives
/// the same 131328 — and it isn't a one-time stamp that can be corrected afterwards. AppKit
/// rewrote the behavior three times over the first half-second of a launch, the last at ~0.4s,
/// each time dropping the flag again; any fixed delay is a guess about a machine that isn't
/// this one.
///
/// So the flag is re-asserted from a KVO observer instead, which is timing-free and also covers
/// the rewrite that comes with every activation-policy flip — one per window open and close.
/// The `contains` check is what stops it recursing: the insert is itself a change.
private final class FullScreenEnablingView: NSView {
    private var observation: NSKeyValueObservation?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            observation = nil
            return
        }
        Self.allowFullScreen(window)
        observation = window.observe(\.collectionBehavior) { window, _ in
            MainActor.assumeIsolated { Self.allowFullScreen(window) }
        }
    }

    private static func allowFullScreen(_ window: NSWindow) {
        guard !window.collectionBehavior.contains(.fullScreenPrimary) else { return }
        window.collectionBehavior.insert(.fullScreenPrimary)
    }
}

private struct FullScreenEnabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { FullScreenEnablingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// True only under `--render`.
///
/// `ImageRenderer` can't rasterize AppKit-backed controls — `TextField`, `Picker` and
/// `Button` all come out as a yellow "no entry" block, which is fine to ignore while
/// checking layout but not in a screenshot anyone else looks at. Views that use one
/// substitute a plain-SwiftUI stand-in showing the same value.
///
/// `PillPicker` exists for the same reason, one step earlier: it replaced a native
/// `Picker` outright rather than needing a stand-in.
private struct OffscreenRenderKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isOffscreenRender: Bool {
        get { self[OffscreenRenderKey.self] }
        set { self[OffscreenRenderKey.self] = newValue }
    }
}
