import AppKit
import SwiftUI

/// Fixed geometry of the panel.
///
/// Hovering a row expands it, which regularly pushes the list past its 400pt cap —
/// and the moment the scroller appears, macOS takes its 15pt out of the content
/// width, so every line of text rewraps right under the cursor. Everything is
/// therefore laid out as if the scroller were always there: the text column is
/// pinned to a width that already excludes the lane, so the scroller slides into
/// empty space instead of pushing anything around.
@MainActor
private enum Panel {
    static let width: CGFloat = 390
    static let inset: CGFloat = 16
    /// 6pt dot + the 10pt gap after it.
    static let dotColumn: CGFloat = 16
    static let scrollerLane = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)

    /// Trailing side carries the lane, so header, footer and rows keep one right edge
    /// whether or not the scroller is on screen.
    static let trailingInset = inset + scrollerLane
    static let textWidth = width - inset - trailingInset - dotColumn
}

/// Menu bar popover — answers just one question: "What's open right now?"
///
/// Shows only sessions whose terminal is still open. The count has a natural
/// ceiling (measured: 11, bounded by how many terminals you actually have open),
/// so there's no need for truncation or a "N more" affordance.
struct MenuBarPanel: View {
    let store: SessionStore
    let preferences: AppPreferences
    let navigation: Navigation
    let updates: UpdateCheck

    @Environment(\.openWindow) private var openWindow
    @Environment(\.theme) private var theme
    @State private var now = Date()

    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            rule

            if store.active.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(store.active.enumerated()), id: \.element.id) { index, item in
                            if index > 0 {
                                rule.padding(.leading, 34)
                            }
                            ActiveRow(item: item, now: now, preferences: preferences)
                        }
                    }
                }
                .frame(maxHeight: 400)
            }

            rule
            footer
        }
        .frame(width: Panel.width)
        .background(theme.bg)
        .task { await store.refresh() }
        .onReceive(ticker) { tick in
            now = tick
            Task { await store.refresh() }
        }
    }

    private var rule: some View {
        Rectangle().fill(theme.rule).frame(height: 1)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(store.headline)
                .font(.system(size: 15, weight: .medium, design: .serif))
                .foregroundStyle(theme.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 10)
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.faint)
            }
            .buttonStyle(.plain)
            .help(L("Rescan"))
        }
        .padding(.leading, Panel.inset)
        .padding(.trailing, Panel.trailingInset)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    /// "Nothing going on" is a good state — it shouldn't look like a blank error page.
    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Theme.dotRunning)
            Text(L("To resume old work, browse from \"All\""))
                .font(Theme.meta)
                .foregroundStyle(theme.faint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }

    private var footer: some View {
        HStack(spacing: 0) {
            if store.runningCount > 0 && store.awaitingCount > 0 {
                Text(L("\(store.runningCount) more running"))
                    .font(Theme.meta)
                    .foregroundStyle(theme.faint)
            }
            Spacer()
            // Routed through the main window rather than presented here: this panel is an
            // `NSPanel` that closes the moment it loses key, which is exactly what putting a
            // sheet or a popover on top of it does. The window is also where the same badge
            // lives, so both roads lead to one sheet.
            if case .available(let release) = updates.state {
                UpdateBadge(version: release.version) {
                    navigation.showingUpdate = true
                    openWindow(id: MainWindow.id)
                }
                .padding(.trailing, 12)
            }
            Button(L("All")) { openWindow(id: MainWindow.id) }
                .buttonStyle(.plain)
                .font(Theme.meta)
                .foregroundStyle(theme.muted)
            SettingsMenu(navigation: navigation, updates: updates)
                .padding(.leading, 14)
        }
        .padding(.leading, Panel.inset)
        .padding(.trailing, Panel.trailingInset)
        .padding(.vertical, 9)
    }
}

// MARK: - One row

/// The star of the show is **your last command** (`last-prompt`).
///
/// Opening this panel from the menu bar, the question you need answered is
/// "what was I just doing in this session" — the thing you said yourself
/// jogs your memory fastest, and 99% of sessions have one.
/// Claude's next step (`away_summary`) only expands after a 0.5s hover: it
/// tends to run longer, and showing it by default would turn the panel into
/// a wall of text, when most of the time you just want to check one row.
private struct ActiveRow: View {
    let item: ResolvedSession
    let now: Date
    let preferences: AppPreferences

    @Environment(\.theme) private var theme
    @State private var isHovering = false
    @State private var expanded = false
    @State private var reveal: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            dot.padding(.top, 5)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.session.projectName)
                        .font(Theme.projectName)
                        .foregroundStyle(theme.muted)
                    Spacer(minLength: 8)
                    Text(RelativeTime.format(item.session.lastActivity, from: now))
                        .font(Theme.meta)
                        .foregroundStyle(theme.faint)
                }
                SpeakerLine(speaker: L("You"), text: youSaid, emphasized: true)
                if expanded {
                    SpeakerLine(
                        speaker: item.session.agent.label,
                        text: summary.text,
                        emphasized: summary.hasSummary,
                        lineLimit: 4
                    )
                }
            }
            .frame(width: Panel.textWidth, alignment: .leading)
        }
        .padding(.leading, Panel.inset)
        .padding(.vertical, 11)
        // Pinned text column + full-width frame: wrapping never changes, but the hover
        // highlight still runs to the panel's edge.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovering ? theme.hover : .clear)
        .contentShape(.rect)
        .onHover(perform: hover)
        .onDisappear { reveal?.cancel() }
        .onTapGesture { SessionActions.jump(item, fallback: preferences.terminal) }
        .contextMenu { SessionMenu(item: item, preferences: preferences) }
    }

    /// Expands only after a 0.5s hover.
    ///
    /// Expanding pushes every row below it down, so it **can't** open the instant
    /// you hover — if the cursor is just passing through the list, every row
    /// popping open would make the whole panel jitter, and the row that gets
    /// pushed away is often the one you were about to click. Collapsing has no
    /// delay, though: it should snap back the moment the cursor leaves.
    private func hover(_ hovering: Bool) {
        isHovering = hovering
        reveal?.cancel()
        guard hovering else {
            withAnimation(.snappy(duration: 0.1)) { expanded = false }
            return
        }
        reveal = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy(duration: 0.14)) { expanded = true }
        }
    }

    /// Don't leave it blank when there's no summary — a blank reads as broken or
    /// still loading. Say plainly that there isn't one, and why.
    private var summary: (text: String, hasSummary: Bool) {
        if let ai = item.actionLine { return (ai, true) }
        if item.state == .running { return (L("Still running — hasn't wrapped up yet."), false) }
        return (L("This session left no summary — Claude only writes one when you step away."), false)
    }

    @ViewBuilder
    private var dot: some View {
        switch item.state {
        case .running: PulsingDot()
        case .awaiting: Circle().fill(Theme.dotWaiting).frame(width: 6, height: 6)
        case .finished: Circle().strokeBorder(theme.faint, lineWidth: 1).frame(width: 6, height: 6)
        }
    }

    /// Short sessions with no last-prompt (measured: 1 out of 118) fall back to the title.
    private var youSaid: String {
        item.session.youSaid ?? item.session.displayTitle
    }
}

// MARK: - Shared components

struct PulsingDot: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Theme.dotRunning)
            .frame(width: 6, height: 6)
            .opacity(dim ? 0.3 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(), value: dim)
            .onAppear { dim = true }
    }
}

struct SessionMenu: View {
    let item: ResolvedSession
    let preferences: AppPreferences

    var body: some View {
        Button(item.isLive ? L("Switch back to original window") : L("Open new window to resume")) {
            SessionActions.jump(item, fallback: preferences.terminal)
        }
        Button(L("Copy resume command")) { SessionActions.copyResumeCommand(item.session) }
        Divider()
        Button(L("Open in \(preferences.editor.displayName)")) {
            SessionActions.openInEditor(item.session, using: preferences.editor)
        }
        Button(L("Reveal in Finder")) { SessionActions.revealInFinder(item.session) }
    }
}

/// Actions only. All preferences live in the settings window — scattering them
/// across two places would leave you unsure where to change what.
struct SettingsMenu: View {
    let navigation: Navigation
    let updates: UpdateCheck

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu {
            // Opens the main window *onto* the usage tab — which is the whole reason the
            // selected page lives in `Navigation` rather than in the window's own `@State`.
            Button(L("Usage")) {
                navigation.mode = .usage
                openWindow(id: MainWindow.id)
            }
            Button(L("Settings…")) {
                navigation.mode = .settings
                openWindow(id: MainWindow.id)
            }
            .keyboardShortcut(",", modifiers: .command)
            Divider()
            Button(L("Quit Your Turn")) { NSApplication.shared.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 16)
        .foregroundStyle(.secondary)
    }
}

enum RelativeTime {
    static func format(_ date: Date, from now: Date) -> String {
        let s = Int(now.timeIntervalSince(date))
        switch s {
        case ..<60: return L("just now")
        case ..<3600: return L("\(s / 60)m ago")
        case ..<86400: return L("\(s / 3600)h ago")
        case ..<(7 * 86400): return L("\(s / 86400)d ago")
        default: return L("\(s / (7 * 86400))w ago")
        }
    }

    /// The same scale pointed the other way, for the one date in the app that hasn't happened
    /// yet: when a Codex allowance window resets. `format` measures `now - date` and would
    /// collapse every future date into "just now" — the reset is always ahead, so it would
    /// have read "Resets just now" for the entire week.
    static func until(_ date: Date, from now: Date) -> String {
        let s = Int(date.timeIntervalSince(now))
        switch s {
        case ..<60: return L("any moment")
        case ..<3600: return L("in \(s / 60)m")
        case ..<86400: return L("in \(s / 3600)h")
        default: return L("in \(s / 86400)d")
        }
    }
}
