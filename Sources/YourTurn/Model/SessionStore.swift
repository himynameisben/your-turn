import Foundation
import Observation

@Observable
@MainActor
final class SessionStore {
    private(set) var groups: [ProjectGroup] = []
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?

    let archive = ArchiveStore()
    let pins = PinStore()

    /// The headline. Deliberately positive phrasing — "have updates" instead of "stuck on
    /// you," "take a look" instead of "pending." This app gets glanced at ~20 times a day,
    /// and the tone is part of the product experience — it shouldn't manufacture pressure
    /// every single time.
    ///
    /// Spelled out per plural form rather than splicing an "s" in, the same two-key shape the
    /// archive/star summaries use: zh-Hant maps both keys to one sentence, so two languages
    /// need no stringsdict. Two counts in one sentence means four keys — and all four cases
    /// occur: one project can hold two waiting sessions, two projects can hold one.
    var headline: String {
        let awaiting = awaitingCount
        let projects = activeProjects.count
        if awaiting == 0 && runningCount == 0 { return L("All wrapped up — nice work today.") }
        if awaiting == 0 {
            return projects == 1
                ? L("\(projects) project running, Claude's still working.")
                : L("\(projects) projects running, Claude's still working.")
        }
        switch (projects == 1, awaiting == 1) {
        case (true, true): return L("\(projects) project has updates, \(awaiting) session waiting for you.")
        case (true, false): return L("\(projects) project has updates, \(awaiting) sessions waiting for you.")
        case (false, true): return L("\(projects) projects have updates, \(awaiting) session waiting for you.")
        case (false, false): return L("\(projects) projects have updates, \(awaiting) sessions waiting for you.")
        }
    }

    /// Starred projects first, the rest sorted by last activity.
    func sorted(_ projects: [ProjectGroup]) -> [ProjectGroup] {
        projects.sorted { a, b in
            let pa = pins.isPinned(a.path), pb = pins.isPinned(b.path)
            if pa != pb { return pa }
            return a.lastActivity > b.lastActivity
        }
    }

    // MARK: - Primary UI: active sessions only

    /// All sessions whose terminal is still open, **sorted purely by last activity time**.
    ///
    /// This used to bump the whole "waiting for you" batch to the top, with the result
    /// that a session Claude is actively running — even one you gave a command to 30
    /// seconds ago — would get pushed to the bottom of the list, looking unsorted. State
    /// already has its own visual language (pulsing green dot / amber dot), so order
    /// doesn't need to say it again.
    ///
    /// The count is naturally capped — bounded by how many terminals you actually have
    /// open (measured: 12), unlike history sessions which can pile up into the hundreds.
    var active: [ResolvedSession] {
        groups.flatMap(\.active)
            .filter { !archive.isArchived($0.id) }
            .sorted { $0.session.lastActivity > $1.session.lastActivity }
    }

    var awaitingCount: Int { active.count { $0.state == .awaiting } }
    var runningCount: Int { active.count { $0.state == .running } }

    /// The number on the menu bar icon. Counts only "waiting for you" — running sessions
    /// don't need you to step in.
    var badgeCount: Int { awaitingCount }

    // MARK: - Grid: project cards

    /// Projects with an active session, starred ones sorted first.
    var activeProjects: [ProjectGroup] {
        sorted(groups.filter(\.hasActive))
    }

    /// The remaining projects, which only have history to resume.
    var idleProjects: [ProjectGroup] {
        sorted(groups.filter { !$0.hasActive })
    }

    // MARK: - Resume list

    /// A project's history sessions, for the user to browse and pick up manually.
    func history(for group: ProjectGroup, matching query: String = "") -> [ResolvedSession] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        return group.history
            .filter { item in
                guard !archive.isArchived(item.id) else { return false }
                guard !trimmed.isEmpty else { return true }
                return item.session.displayTitle.lowercased().contains(trimmed)
                    || (item.session.displayDetail?.lowercased().contains(trimmed) ?? false)
            }
            .sorted { $0.session.lastActivity > $1.session.lastActivity }
    }

    /// Searches history across all projects, for "I remember doing something but forgot
    /// which project" moments.
    func searchHistory(_ query: String) -> [ResolvedSession] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return [] }
        return groups.flatMap { group in
            group.history.filter { item in
                !archive.isArchived(item.id) && (
                    group.name.lowercased().contains(trimmed)
                        || item.session.displayTitle.lowercased().contains(trimmed)
                        || (item.session.displayDetail?.lowercased().contains(trimmed) ?? false)
                )
            }
        }
        .sorted { $0.session.lastActivity > $1.session.lastActivity }
    }

    // MARK: -

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // Scanning is synchronous file I/O (measured ~40ms); offload to background so it
        // doesn't stall the menu's open animation.
        groups = await Task.detached(priority: .utility) {
            let sessions = SessionScanner.scan()
            let processes = ProcessProbe.liveProcesses()
            let registry = SessionRegistry.read(livePIDs: Set(processes.map(\.pid)))
            return SessionResolver.resolve(sessions, processes: processes, registry: registry)
        }.value
        lastRefresh = Date()
    }

    /// Demo/preview only (`--render … --demo`): swaps in handcrafted groups instead of
    /// scanning. README screenshots would otherwise publish the real `~/.claude` — titles,
    /// prompts and summaries straight out of someone's working day.
    func loadDemo(_ demo: [ProjectGroup]) {
        groups = demo
        lastRefresh = Date()
    }
}
