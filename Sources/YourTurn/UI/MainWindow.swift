import SwiftUI

/// Full window — an editorial two-column layout: project names in the left gutter, content on the right.
///
/// No cards, no borders — whitespace and rules do the sectioning. The goal is for it to read like
/// a morning briefing, not a monitoring dashboard.
struct MainWindow: View {
    static let id = "main"

    let store: SessionStore
    let stats: StatsStore
    let preferences: AppPreferences
    let navigation: Navigation
    let updates: UpdateCheck

    @Environment(\.theme) private var theme
    @State private var query = ""
    @State private var now = Date()

    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    /// The four pages this window shows. Two of them group the same session list; the other two
    /// are different subjects entirely, and they sit in the same picker anyway — from where
    /// you're standing these are just "what am I looking at", which is what a tab is.
    ///
    /// Settings became one of them rather than keeping a window of its own: an app that lives in
    /// the menu bar and usually has no windows at all shouldn't answer a click by opening a
    /// second one.
    enum Mode: String, CaseIterable, Identifiable {
        case byTime = "By time"
        case byProject = "By project"
        case usage = "Usage"
        case settings = "Settings"
        var id: String { rawValue }

        /// `rawValue` stays English on purpose — it's the `Identifiable` id, so translating it
        /// would make the selection identity change with the system language.
        var displayName: String {
            switch self {
            case .byTime: L("By time")
            case .byProject: L("By project")
            case .usage: L("Usage")
            case .settings: L("Settings")
            }
        }

        /// True for the pages that aren't the session list, which is what the search field
        /// searches. Both fade it out rather than removing it — see the masthead.
        var isSessionList: Bool { self == .byTime || self == .byProject }
    }

    var body: some View {
        ScrollView {
            MainWindowPage(
                store: store,
                stats: stats,
                preferences: preferences,
                navigation: navigation,
                updates: updates,
                mode: Bindable(navigation).mode,
                query: $query,
                now: now,
                showingUpdate: Bindable(navigation).showingUpdate
            )
        }
        .background(theme.bg)
        .frame(minWidth: 720, minHeight: 520)
        // Presented from the window, not the page: the page is what `--render` rasterizes, and a
        // sheet modifier there would attach to a view that never gets a window to hang off.
        .updateSheet(updates.state, isPresented: Bindable(navigation).showingUpdate)
        .task {
            await store.refresh()
            await stats.refreshQuotas(sessions: store.sessions)
        }
        .onReceive(ticker) { tick in
            now = tick
            // Only the session scan is on this timer. Usage is far heavier and re-reads
            // nothing on its own — see `StatsStore.loadIfNeeded`. The allowance rides along
            // because it is two file reads and it lives in the masthead, which is on screen.
            Task {
                await store.refresh()
                await stats.refreshQuotas(sessions: store.sessions)
            }
        }
    }

}

/// Which page the main window is showing.
///
/// Held outside the window rather than in `@State` for two reasons: the menu bar's "Usage"
/// item has to be able to open the window *onto* that page, and a language switch re-ids the
/// whole subtree (see `Localization`), which would otherwise bounce you back to the session
/// list mid-read.
///
/// Deliberately not persisted. The inbox is the product — opening onto a spend page because
/// you glanced at it last week would be the wrong first impression every morning.
@Observable
@MainActor
final class Navigation {
    var mode: MainWindow.Mode = .byProject

    /// Also set by the menu bar panel's badge, which opens the window *with the sheet already up* —
    /// same reason `mode` lives here rather than in the window's `@State`.
    var showingUpdate = false

    /// A row the window should scroll to once it exists. Set by the masthead's allowance rings,
    /// cleared by that row's own `onAppear` — a request, not a position, so nothing here can
    /// disagree with where the page actually is.
    var pendingScroll: String?

    /// Switch to a page and ask to land on one of its rows.
    func open(_ mode: MainWindow.Mode, scrollingTo anchor: String? = nil) {
        self.mode = mode
        pendingScroll = anchor
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
    let stats: StatsStore
    let preferences: AppPreferences
    /// Optional so `--render` can rasterize this page without one; the rings simply don't respond.
    var navigation: Navigation?
    let updates: UpdateCheck
    @Binding var mode: MainWindow.Mode
    @Binding var query: String
    let now: Date
    @Binding var showingUpdate: Bool

    @Environment(\.theme) private var theme
    @Environment(\.isOffscreenRender) private var isOffscreenRender

    var body: some View {
        // VStack, not LazyVStack: project counts run from single digits to the teens, so lazy
        // loading saves nothing — and it would just as surely leave offscreen rendering with
        // nothing laid out.
        VStack(alignment: .leading, spacing: 0) {
            masthead
            Rectangle().fill(theme.rule).frame(height: 1)

            if mode == .usage {
                UsageSections(store: stats, now: now, navigation: navigation)
                    // Scans on arrival, not on the window's 30-second timer — and
                    // `loadIfNeeded` skips the work entirely when you flip back within a
                    // minute, so switching tabs stays free.
                    .task { await stats.loadIfNeeded() }
            } else if mode == .settings {
                SettingsPage(
                    store: store, preferences: preferences, updates: updates,
                    showingUpdate: $showingUpdate
                )
            } else if !query.isEmpty {
                searchResults
            } else {
                switch mode {
                case .byProject: projectSections
                case .byTime: timelineSection
                case .usage, .settings: EmptyView()
                }
            }
        }
    }

    // MARK: - Masthead

    private var masthead: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                MastheadKicker(
                    dateline: datelineText,
                    // Only on the session list. The Usage tab draws the same numbers in full a
                    // screen below, and a control whose whole job is "take me there" has nothing
                    // to offer once you're already there.
                    quotas: mode.isSessionList ? stats.quotas : [],
                    now: now,
                    onSelect: select
                )
                Text(headlineText)
                    .font(Theme.display)
                    .foregroundStyle(theme.text)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 20)
            VStack(alignment: .trailing, spacing: 10) {
                // The search box only searches sessions, so it goes blank on the usage and
                // settings pages rather than sitting there inert. Faded and disabled rather than
                // removed: taking it out of the stack pulls the tab picker up by the height of a
                // text field, sliding the control you just clicked out from under the cursor.
                // `disabled` is what keeps an invisible field out of the keyboard focus chain.
                searchField
                    .opacity(mode.isSessionList ? 1 : 0)
                    .disabled(!mode.isSessionList)
                HStack(spacing: 8) {
                    if case .available(let release) = updates.state {
                        UpdateBadge(version: release.version) { showingUpdate = true }
                    }
                    // No gear button any more: settings is one of the pills to its right, and two
                    // controls opening the same page next to each other is one too many.
                    PillPicker(options: MainWindow.Mode.allCases, selection: $mode) { $0.displayName }
                }
            }
        }
        .padding(.horizontal, Theme.pageInset)
        .padding(.top, 30)
        .padding(.bottom, 26)
    }

    /// A reading takes you to the row it came from; the empty slot takes you to the switch that
    /// would fill it. Both are one click, because "you have no Claude number" and "here is how to
    /// get one" are the same sentence from where the cursor is.
    private func select(_ item: AllowanceRings.Item) {
        switch item {
        case .quota: navigation?.open(.usage, scrollingTo: UsageSections.allowanceAnchor)
        case .setup: navigation?.open(.settings)
        }
    }

    /// Each tab names itself in the kicker. Settings gets a fixed pair rather than anything
    /// computed: there is no number about your preferences worth putting in 27pt serif.
    private var datelineText: String {
        switch mode {
        case .usage: UsageMasthead.dateline(stats.summary, period: stats.period)
        case .settings: L("SETTINGS")
        case .byTime, .byProject: dateline
        }
    }

    private var headlineText: String {
        switch mode {
        case .usage: UsageMasthead.headline(stats.summary, period: stats.period)
        case .settings: L("How Your Turn behaves.")
        case .byTime, .byProject: store.headline
        }
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
                    SessionLine(item: item, now: now, preferences: preferences, showsAgent: store.showsAgentBadges)
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
                    SessionLine(item: item, now: now, preferences: preferences, showsAgent: store.showsAgentBadges)
                }
                Rectangle().fill(theme.rule).frame(height: 1)
            }
        }
    }
}

// MARK: - Masthead kicker

/// The small line above the headline: the date, the allowance rings, and — while the cursor is on
/// one — what that ring says.
///
/// **A view of its own, holding the hover state, for two reasons that both showed up the moment
/// this was used with a real mouse.**
///
/// The first is cost. Kept in `MainWindowPage`, every hover invalidated that whole body: the
/// masthead, thirty-odd project blocks and every session line under them. One line of the header
/// should not repaint the page it sits on.
///
/// The second is worse, and it's why the detail is drawn *after* the rings instead of replacing
/// the dateline. Swapping the dateline changes its width, the rings sit after it in the row, and
/// so they slid right the instant the cursor arrived — out from under the cursor, which ended the
/// hover, which restored the short text, which slid them back under it. A layout feedback loop
/// running at refresh rate, repainting everything each time round: it beachballed. Nothing before
/// the rings changes size now, so nothing can move them.
struct MastheadKicker: View {
    let dateline: String
    let quotas: [AgentQuota]
    let now: Date
    let onSelect: (AllowanceRings.Item) -> Void

    @Environment(\.theme) private var theme
    @State private var hovered: AllowanceRings.Item?

    /// `initialHover` exists for `--render` alone. The bug this view was rewritten for was a
    /// layout bug that only appeared under the cursor, and a screenshot of the resting state
    /// could never have shown it — so the hovered state gets a frame of its own, where the two
    /// are stacked and the rings either line up or they don't.
    init(
        dateline: String,
        quotas: [AgentQuota],
        now: Date,
        onSelect: @escaping (AllowanceRings.Item) -> Void,
        initialHover: AllowanceRings.Item? = nil
    ) {
        self.dateline = dateline
        self.quotas = quotas
        self.now = now
        self.onSelect = onSelect
        _hovered = State(initialValue: initialHover)
    }

    var body: some View {
        HStack(spacing: 14) {
            Text(dateline)
                .font(Theme.meta)
                .tracking(0.6)
                .foregroundStyle(theme.faint)
                .lineLimit(1)
                .fixedSize()

            if !quotas.isEmpty {
                AllowanceRings(quotas: quotas, now: now, hovered: $hovered, onSelect: onSelect)

                if let hovered {
                    Text(hovered.summary())
                        .font(Theme.meta)
                        .tracking(0.6)
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                        // Everything to the left of this is fixed width, so this can only ever
                        // grow into the empty half of the row — and at the window's 720pt minimum,
                        // where there is less of that, it truncates instead of pushing.
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 0)
        }
        .animation(.easeOut(duration: 0.1), value: hovered)
    }
}

// MARK: - Allowance rings

/// The allowance, in the masthead, as one ring per window.
///
/// Up here rather than only on the Usage tab because "is there room to start something" is a
/// question you have *before* you pick a session, and a tab you have to remember to open is a
/// number you never see. Rings rather than the bars used below: three bars wide enough to read
/// would take the headline's line, and at 18pt a gauge that isn't full is legible without reading
/// anything at all.
///
/// The detail is printed by the dateline this sits next to — same row, same font, so revealing it
/// moves nothing on the page and it's already where the eye is. `.help()` carries the same text
/// for anyone who waits instead of reading, and a popover was not used: it would be a floating
/// panel over a window whose whole design is flat.
struct AllowanceRings: View {
    enum Item: Equatable, Identifiable {
        case quota(AgentQuota)
        /// No Claude reading — either the bridge is off, or it's on and Claude Code hasn't
        /// replied since. Both end at the same row of the settings page, which explains both.
        case setup

        var id: String {
            switch self {
            case .quota(let quota): quota.id
            case .setup: "setup"
            }
        }

        /// What the dateline is swapped for. Kept to roughly the length of a date, because the
        /// dateline is one line at the window's 720pt minimum and a detail that truncates to
        /// "Claude · 7-d…" is worse than the date it replaced. The reset time is the part that
        /// gives way — it's in the tooltip, and in full on the page the ring links to.
        func summary() -> String {
            guard case .quota(let quota) = self else { return L("Claude allowance — not set up") }
            let left = L("\(StatsFormat.percentUsed(quota.remainingPercent)) left")
            return "\(quota.agent.label) · \(quota.windowLabel) — \(left)"
        }

        func detail(now: Date) -> String {
            guard case .quota(let quota) = self else {
                return L("No Claude reading yet — switch the status-line bridge on in Settings.")
            }
            let reset = quota.resetsAt.map { " · " + L("Resets \(RelativeTime.until($0, from: now))") } ?? ""
            return summary() + reset
        }
    }

    let quotas: [AgentQuota]
    let now: Date
    @Binding var hovered: Item?
    let onSelect: (Item) -> Void

    var body: some View {
        HStack(spacing: 7) {
            ForEach(items) { item in
                ring(item)
            }
        }
        // The cluster empties itself when the cursor leaves it entirely — an individual ring's
        // `onHover(false)` can arrive after the next ring's `onHover(true)` while sliding across,
        // which would blank the dateline mid-read.
        .onHover { if !$0 { hovered = nil } }
    }

    /// Claude's two windows first, then Codex's one: the five-hour window is the one that stops
    /// you in the next hour, and it's the reason to look at all.
    private var items: [Item] {
        var items = quotas.map(Item.quota)
        if !quotas.contains(where: { $0.agent == .claude }) { items.insert(.setup, at: 0) }
        return items
    }

    private func ring(_ item: Item) -> some View {
        let quota: AgentQuota? = if case .quota(let quota) = item { quota } else { nil }
        return AllowanceRing(
            remaining: quota?.remainingPercent,
            isLow: quota?.isLow ?? false,
            highlighted: hovered == item
        )
        // The hit target is this fixed 22pt box, not the ring drawn inside it. `AllowanceRing`
        // grows a little when highlighted, and hit-testing a shape that changes size with the
        // hover state is how you get a control that flickers on its own edge. It also makes an
        // 18pt target easier to land on.
        .frame(width: 22, height: 22)
        .contentShape(.rect)
        .onHover { inside in
            // Assign only on a real change: an unchanged `@State` write still invalidates.
            if inside {
                if hovered != item { hovered = item }
            } else if hovered == item {
                hovered = nil
            }
        }
        .onTapGesture { onSelect(item) }
        .help(item.detail(now: now))
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
            .frame(width: Theme.gutter, alignment: .trailing)
            .padding(.trailing, 22)
            .contentShape(.rect)
            .onHover { isHovering = $0 }

            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, Theme.pageInset)
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
                    SessionLine(item: item, now: now, preferences: preferences, showsAgent: store.showsAgentBadges)
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
    /// Passed down rather than read here: it's a property of the whole list, and every row
    /// has to agree, or the column would show a badge on some rows and not others.
    var showsAgent = false

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
            if showsAgent {
                AgentBadge(agent: item.session.agent)
            }
            // Only shows up when the registry says it's stuck on a prompt — the only
            // state where "it won't move until you answer" is true. Codex never reaches
            // this: it writes no approval state to disk at all.
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
            SpeakerLine(speaker: item.session.agent.label, text: ai, emphasized: true)
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


