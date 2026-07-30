import SwiftUI

/// Full window — an editorial two-column layout: project names in the left gutter, content on the right.
///
/// No cards, no borders — whitespace and rules do the sectioning. The goal is for it to read like
/// a morning briefing, not a monitoring dashboard.
struct MainWindow: View {
    static let id = "main"

    let store: SessionStore
    let preferences: AppPreferences

    @Environment(\.theme) private var theme
    @State private var mode: Mode = .byProject
    @State private var query = ""
    @State private var now = Date()

    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    enum Mode: String, CaseIterable, Identifiable {
        case byTime = "By time"
        case byProject = "By project"
        var id: String { rawValue }

        /// `rawValue` stays English on purpose — it's the `Identifiable` id, so translating it
        /// would make the selection identity change with the system language.
        var displayName: String {
            switch self {
            case .byTime: L("By time")
            case .byProject: L("By project")
            }
        }
    }

    var body: some View {
        ScrollView {
            MainWindowPage(
                store: store,
                preferences: preferences,
                mode: $mode,
                query: $query,
                now: now
            )
        }
        .background(theme.bg)
        .frame(minWidth: 720, minHeight: 520)
        .task { await store.refresh() }
        .onReceive(ticker) { tick in
            now = tick
            Task { await store.refresh() }
        }
    }

}

/// The whole scrollable page inside the window.
///
/// Split out from `MainWindow` because `ImageRenderer` doesn't expand `ScrollView` content
/// (measured: it renders only the background color, not a single word) — and `--render` needs
/// to be able to render this page directly. A nice side effect of the split: this page no
/// longer depends on any window lifecycle, it's a pure mapping from data to layout.
struct MainWindowPage: View {
    let store: SessionStore
    let preferences: AppPreferences
    @Binding var mode: MainWindow.Mode
    @Binding var query: String
    let now: Date

    @Environment(\.theme) private var theme
    @Environment(\.isOffscreenRender) private var isOffscreenRender

    var body: some View {
        // VStack, not LazyVStack: project counts run from single digits to the teens, so lazy
        // loading saves nothing — and it would just as surely leave offscreen rendering with
        // nothing laid out.
        VStack(alignment: .leading, spacing: 0) {
            masthead
            Rectangle().fill(theme.rule).frame(height: 1)

            if !query.isEmpty {
                searchResults
            } else {
                switch mode {
                case .byProject: projectSections
                case .byTime: timelineSection
                }
            }
        }
    }

    // MARK: - Masthead

    private var masthead: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text(dateline)
                    .font(Theme.meta)
                    .tracking(0.6)
                    .foregroundStyle(theme.faint)
                Text(store.headline)
                    .font(Theme.display)
                    .foregroundStyle(theme.text)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 20)
            VStack(alignment: .trailing, spacing: 10) {
                searchField
                HStack(spacing: 8) {
                    SettingsButton()
                    PillPicker(options: MainWindow.Mode.allCases, selection: $mode) { $0.displayName }
                }
            }
        }
        .padding(.horizontal, 38)
        .padding(.top, 30)
        .padding(.bottom, 26)
    }

    private var dateline: String {
        let f = DateFormatter()
        // Follows the language the UI resolved to, not `Locale.current`: an English UI on a
        // Taiwanese machine must not print a weekday as "星期二" under an English headline.
        f.locale = Localization.locale
        // The pattern is translated too — it renders as "July 28 · Tuesday" in en and
        // "7月28日 · 星期二" in zh-Hant, which is not a reordering of the same fields, so a
        // single format string can't serve both.
        f.dateFormat = L("dateline.format")
        return f.string(from: now)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(theme.faint)
            Group {
                if isOffscreenRender {
                    Text(query.isEmpty ? L("Search sessions…") : query)
                        .foregroundStyle(query.isEmpty ? theme.faint : theme.text)
                        .frame(width: 150, alignment: .leading)
                } else {
                    TextField(L("Search sessions…"), text: $query)
                        .textFieldStyle(.plain)
                        .foregroundStyle(theme.text)
                        .frame(width: 150)
                }
            }
            .font(Theme.meta)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(theme.rule, lineWidth: 1)
        )
    }

    // MARK: - By project

    @ViewBuilder
    private var projectSections: some View {
        let active = store.activeProjects
        let idle = store.idleProjects

        ForEach(active) { group in
            ProjectBlock(group: group, store: store, preferences: preferences, now: now)
            Rectangle().fill(theme.rule).frame(height: 1)
        }

        if !idle.isEmpty {
            IdleProjectsBlock(projects: idle, store: store, now: now)
        }

        if active.isEmpty && idle.isEmpty {
            Text(store.lastRefresh == nil ? L("Scanning…") : L("No sessions found"))
                .font(Theme.lede)
                .foregroundStyle(theme.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 70)
        }
    }

    // MARK: - By time

    @ViewBuilder
    private var timelineSection: some View {
        let items = store.active
        if items.isEmpty {
            Text(L("No sessions are open right now"))
                .font(Theme.lede)
                .foregroundStyle(theme.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 70)
        } else {
            ForEach(items) { item in
                GutterRow(label: item.session.projectName) {
                    SessionLine(item: item, now: now, preferences: preferences)
                }
                Rectangle().fill(theme.rule).frame(height: 1)
            }
        }
    }

    // MARK: - Search

    @ViewBuilder
    private var searchResults: some View {
        let results = store.searchHistory(query)
        if results.isEmpty {
            Text(L("No sessions match \"\(query)\""))
                .font(Theme.lede)
                .foregroundStyle(theme.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 70)
        } else {
            ForEach(results.prefix(80)) { item in
                GutterRow(label: item.session.projectName) {
                    SessionLine(item: item, now: now, preferences: preferences)
                }
                Rectangle().fill(theme.rule).frame(height: 1)
            }
        }
    }
}

// MARK: - Two-column skeleton

/// Right-aligned label in the left gutter, content on the right. The whole layout aligns to this skeleton.
private struct GutterRow<Content: View>: View {
    let label: String?
    var starred = false
    var onStar: (() -> Void)?
    /// Count of sessions waiting for you; falls back to the running count when there are none.
    var awaiting = 0
    var running = 0
    @ViewBuilder let content: Content

    @Environment(\.theme) private var theme
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            HStack(spacing: 5) {
                Spacer(minLength: 0)
                // Reserve room for the star and badge whenever this row has a label, even if
                // it has neither (e.g. "Done for now") — without the slot, that row's project
                // name would stick out further than the others.
                if label != nil {
                    StarToggle(isOn: starred, revealed: isHovering, action: onStar)
                }
                if let label {
                    Text(label)
                        .font(Theme.projectName)
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    countBadge
                }
            }
            // 168, not the original 150: once the star and badge each take a slot, 150 would
            // middle-elide a 19-character project name, which is an ordinary length here.
            .frame(width: 168, alignment: .trailing)
            .padding(.trailing, 22)
            .contentShape(.rect)
            .onHover { isHovering = $0 }

            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 38)
        }
        .padding(.vertical, 20)
    }

    /// Fixed-width badge slot: it's what lines the right edge of the project names up
    /// straight, and lets the badges themselves form their own column, like unread
    /// counts in an inbox.
    ///
    /// Shows only one number. "Waiting for you" takes priority — running sessions
    /// don't need you to step in, and each row's own status dot is already saying the
    /// same thing. Showing both counts side by side would just re-grow the row we
    /// just trimmed down.
    @ViewBuilder
    private var countBadge: some View {
        Group {
            if awaiting > 0 {
                CountBadge(count: awaiting, tone: theme.waitingChip)
            } else if running > 0 {
                CountBadge(count: running, tone: theme.runningChip)
            }
        }
        .frame(width: 18)
    }
}

/// Star toggle: a fixed slot right next to the project name.
///
/// The old version overlaid it at the far left of the gutter, 100pt away from the
/// project name — it looked like debris that had fallen off the edge of the page.
/// It also drew a separate 8pt icon for "starred," so the same thing showed up in
/// two places. Now it's one thing: starred is filled, otherwise invisible, and
/// hovering the row reveals it outlined — same position, same size either way.
private struct StarToggle: View {
    let isOn: Bool
    /// Mouse is over this row — only relied on to reveal the toggle when it's unstarred.
    let revealed: Bool
    let action: (() -> Void)?

    @Environment(\.theme) private var theme

    var body: some View {
        Button { action?() } label: {
            Image(systemName: isOn ? "star.fill" : "star")
                .font(.system(size: 11))
                .foregroundStyle(isOn ? theme.text : theme.faint)
                .opacity(action == nil ? 0 : (isOn || revealed ? 1 : 0))
                .frame(width: 15, height: 15)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .help(isOn ? L("Remove star") : L("Star to pin to the top"))
    }
}

// MARK: - Project block

private struct ProjectBlock: View {
    let group: ProjectGroup
    let store: SessionStore
    let preferences: AppPreferences
    let now: Date

    var body: some View {
        GutterRow(
            label: group.name,
            starred: store.pins.isPinned(group.path),
            onStar: { store.pins.toggle(group.path) },
            awaiting: group.awaitingCount,
            running: group.runningCount
        ) {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(group.active) { item in
                    SessionLine(item: item, now: now, preferences: preferences)
                }
            }
        }
    }
}

/// Done-for-now projects are collapsed into a single block, keeping only the project
/// name and resume count — they shouldn't compete with running ones for space.
private struct IdleProjectsBlock: View {
    let projects: [ProjectGroup]
    let store: SessionStore
    let now: Date

    @Environment(\.theme) private var theme
    @State private var expanded = false

    var body: some View {
        GutterRow(label: expanded ? L("Done for now") : nil) {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    withAnimation(.snappy(duration: 0.16)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Text(projects.count == 1
                            ? L("\(projects.count) more project done for now — resume an old session")
                            : L("\(projects.count) more projects done for now — resume an old session"))
                            .font(Theme.meta)
                    }
                    .foregroundStyle(theme.muted)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)

                if expanded {
                    ForEach(projects) { group in
                        HStack(spacing: 8) {
                            Text(group.name)
                                .font(Theme.sessionTitle)
                                .foregroundStyle(theme.muted)
                            Text(L("\(store.history(for: group).count) resumable"))
                                .font(Theme.meta)
                                .foregroundStyle(theme.faint)
                            Spacer()
                            Text(RelativeTime.format(group.lastActivity, from: now))
                                .font(Theme.meta)
                                .foregroundStyle(theme.faint)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Components

private struct Chip: View {
    let text: String
    let tone: Theme.ChipTone

    var body: some View {
        Text(text)
            .font(Theme.chip)
            .foregroundStyle(tone.fg)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tone.bg, in: .rect(cornerRadius: 4))
    }
}

/// Three lines per session: title (what it's doing), your last message, and the next
/// step Claude left behind.
///
/// Why these three lines: the title only lets you "recognize" which session this is.
/// Once you recognize it, you still need to recall "what did I ask it to do" and
/// "did it finish, and where's it stuck." Those two things are `last-prompt`
/// (measured: available 99% of the time) and `away_summary` (72%) — different
/// sources, different tone — so they're laid out like a dialogue, your line then
/// its line, so you can read the whole context at a glance.
///
/// Branch was dropped: it's almost always main/HEAD, taking up a line without
/// changing your next move.
struct SessionLine: View {
    let item: ResolvedSession
    let now: Date
    let preferences: AppPreferences

    @Environment(\.theme) private var theme
    @State private var isHovering = false

    // Split into a child view instead of one long chain: writing it all inline in
    // body makes SourceKit report "unable to type-check in reasonable time."
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            dot.padding(.top, 5)
            VStack(alignment: .leading, spacing: 5) {
                titleRow
                dialogue
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(isHovering ? theme.hover : .clear, in: .rect(cornerRadius: 5))
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .onTapGesture { SessionActions.jump(item, fallback: preferences.terminal) }
        .help(item.process.map { L("Switch back to \($0.host.displayName)") } ?? L("Open a new window to resume"))
        .contextMenu { SessionMenu(item: item, preferences: preferences) }
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(item.session.displayTitle)
                .font(Theme.sessionTitle)
                .foregroundStyle(theme.muted)
                .lineLimit(1)
            // Only shows up when the registry says it's stuck on a prompt — the only
            // state where "it won't move until you answer" is true.
            if let waitingFor = item.waitingFor {
                Chip(text: L("Waiting for you: \(waitingFor)"), tone: theme.waitingChip)
            }
            Spacer(minLength: 8)
            Text(RelativeTime.format(item.session.lastActivity, from: now))
                .font(Theme.meta)
                .foregroundStyle(theme.faint)
        }
    }

    @ViewBuilder
    private var dialogue: some View {
        if let you = youSaid {
            SpeakerLine(speaker: L("You"), text: you, emphasized: false)
        }
        if let ai = item.actionLine {
            SpeakerLine(speaker: "Claude", text: ai, emphasized: true)
        }
    }

    /// Sessions without a title fall back to last-prompt as the title, which makes
    /// the "You" line redundant.
    private var youSaid: String? {
        guard let said = item.session.youSaid, said != item.session.displayTitle else { return nil }
        return said
    }

    @ViewBuilder
    private var dot: some View {
        switch item.state {
        case .running: PulsingDot()
        case .awaiting: Circle().fill(Theme.dotWaiting).frame(width: 6, height: 6)
        case .finished: Circle().strokeBorder(theme.faint, lineWidth: 1).frame(width: 6, height: 6)
        }
    }
}


/// Opens the settings window. Appearance switching has moved into the settings
/// page — there's room there for four options side by side, so you can see the
/// choice at a glance instead of having to open a dropdown to find out.
private struct SettingsButton: View {
    @Environment(\.theme) private var theme
    @Environment(\.openWindow) private var openWindow
    @State private var isHovering = false

    var body: some View {
        Button {
            openWindow(id: SettingsWindow.id)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 11))
                .foregroundStyle(theme.muted)
                .frame(width: 26, height: 26)
                .background(isHovering ? theme.hover : .clear, in: .rect(cornerRadius: 6))
                .padding(2)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.rule, lineWidth: 1))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(L("Settings"))
    }
}
