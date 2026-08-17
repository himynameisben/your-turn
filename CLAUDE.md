# Your Turn

macOS menu bar app: an inbox for Claude Code. It answers three questions —
**which sessions are open? which one is waiting for me? where did it stop, and
what's next?**

Core premise: Claude Code already writes the answers into `~/.claude`. This app is a
**reader** — it runs no LLM, doesn't parse conversation content, and treats
`~/.claude` as **read-only** (preferences like stars/archive live in UserDefaults).

- Swift 6 / SwiftUI / macOS 15+, no third-party packages
- `LSUIElement`: no Dock icon, no Cmd-Tab entry

## Quick start

```bash
swift build                        # compile
./Scripts/bundle.sh                # assemble build/YourTurn.app (debug)
open build/YourTurn.app            # launch; the icon appears in the menu bar

./Scripts/install.sh               # release build → /Applications, quits the old copy first
```

`MenuBarExtra` and `LSUIElement` both require a real app bundle — running the raw
binary won't work.

Use `install.sh` for the copy you actually live with: "start at login" registers whatever
bundle path it's toggled from, so a login item armed from `build/` breaks the next time
that directory is wiped.

### Verification entry points (no UI, print results directly)

| Command | Purpose |
|---|---|
| `--dump` | Print every session: state, times, your last prompt / Claude's next step, jump target, stats |
| `--triage` | Cross-check how far "terminal still open" and "has pending work" diverge |
| `--next` | Quality stats for next-step extraction (pending / clear / unknown ratio) |
| `--cost [--no-cache] [--refresh-prices]` | Print the usage pipeline: scan timings, dedup counts, total spend, per model / per project / per day, rhythm. `--no-cache` forces a cold scan so both paths can be compared; `--refresh-prices` fires the LiteLLM download the window otherwise only attempts once a day |
| `--login-item [on\|off]` | Read or flip the "start at login" registration. Only meaningful from the binary **inside** the .app (`/Applications/YourTurn.app/Contents/MacOS/YourTurn`) — `SMAppService` answers for the bundle it runs in, and there's no other way to check: these registrations don't show up in AppleScript's login-item list, and the system's database needs root |
| `--update-check` | Print the running version, GitHub's latest release, the verdict, and the version-ordering table (including the two pairs a string comparison gets wrong). Always fetches, ignoring the daily throttle. Also prints what the **app** last stored and how that resolves — the only way to see whether the launch-time check fired, since a machine that's up to date has no UI at all. Seed `updateCheckLatestVersion` / `updateCheckLatestPage` in UserDefaults to exercise the notice without publishing a release |
| `--render <dir> [--demo]` | Offscreen-render the main window in every palette — all four tabs via `MainWindowPage` with the mode pinned, so each PNG is literally the page a user sees — plus `light-narrow.png` (the 720pt minimum width), the update sheet, and the menu bar panel's footer. `--demo` renders invented sessions and invented usage instead of the real scan — **required for anything published**, since a real scan puts your own titles, prompts, summaries and actual spend in the picture |

**Session-layer changes: run `--dump`. Usage-layer changes: run `--cost`. Update-layer
changes: run `--update-check`. Layout changes: run `--render`.** Layout cannot
be eyeballed — `--render` is the only way to actually see the result
(`LSUIElement` windows can't be captured reliably with `screencapture`).

## Directory layout

```
Sources/YourTurn/
├── YourTurnApp.swift           @main. CLI flags are intercepted before any scene is created
├── DumpCommand.swift           --dump / --triage / --next
├── Scanner/                    reads disk, contains no judgment
│   ├── SessionScanner.swift    scans ~/.claude/projects, parses into [Session] concurrently
│   ├── JSONLTailReader.swift   reads only the last 64KB of a file: title / summary / times
│   ├── SessionRegistry.swift   reads ~/.claude/sessions/<pid>.json (pid ↔ sessionId)
│   └── ProcessProbe.swift      pgrep/lsof/ps to find live claude processes and the app hosting each
├── Model/                      judgment and state
│   ├── Session.swift           a single session and its state (running/awaiting/finished)
│   ├── SessionResolver.swift   session × process × registry → ProjectGroup
│   ├── SessionStore.swift      @Observable, the UI's single source of truth
│   ├── SummaryText.swift       extracts the "next step" sentence from away_summary
│   ├── AppPreferences.swift    terminal / editor / appearance / language preferences
│   ├── LaunchAtLogin.swift     start-at-login, via SMAppService — state lives in macOS, not UserDefaults
│   └── UpdateCheck.swift       is a newer release out? GitHub releases API, daily, never installs anything
├── Stats/                      the second pipeline: what it cost, how the days went
│   ├── UsageScanner.swift      full-file scan incl. subagents/, byte prefilter + concurrentPerform
│   ├── UsageRecord.swift       one deduplicated request, split into per-model segments
│   ├── UsageCache.swift        per-file cache keyed on (size, mtime) — 1.5s cold → 36ms warm
│   ├── Pricing.swift           per-iteration, per-model pricing; unknown model → nil, never 0
│   ├── PriceTable.swift        bundled snapshot + optional LiteLLM refresh
│   ├── ProjectRoot.swift       rolls a cwd up to its git repository
│   ├── UsageStats.swift        aggregation: by day / model / project, plus rhythm
│   ├── StatsFormat.swift       $ / token / duration formatting, shared with the CLI
│   ├── StatsStore.swift        @Observable, scans when the usage window opens
│   └── CostCommand.swift       --cost
├── Actions/
│   ├── SessionActions.swift    jump back to the original window, resume, open editor (AppleScript)
│   ├── PinStore.swift          starred projects (UserDefaults key remains pinnedProjects)
│   └── ArchiveStore.swift      archiving
├── UI/
│   ├── MenuBarPanel.swift      menu bar panel, one line per session
│   ├── MainWindow.swift        main window: four tabs, and `Navigation` (which tab is up)
│   ├── UsagePage.swift         the Usage tab's sections + its masthead wording
│   ├── SettingsPage.swift      the settings tab's rows — a page in the main window, not a window
│   ├── Theme.swift             three palettes + type scale, passed via the \.theme environment value
│   ├── Components.swift        PillPicker (never compresses), activation policy
│   ├── UpdateViews.swift       the amber `UpdateBadge` and the one `UpdateSheet` it opens
│   ├── Localization.swift      the `L("…")` helper, `AppLanguage`, and the live-switch scope
│   └── RenderCommand.swift     implementation of --render, plus the --demo fake sessions
└── Resources/
    ├── prices.json             trimmed LiteLLM snapshot (26 Anthropic models, 4.3KB)
    ├── en.lproj/               Localizable.strings (source language) + InfoPlist.strings
    └── zh-Hant.lproj/          the same two files, translated

docs/RELEASING.md               signing & notarization playbook
```

## Data sources (all inside `~/.claude`)

| Path | What it provides |
|---|---|
| `projects/<slug>/<uuid>.jsonl` | the session itself: `ai-title`, `away_summary`, `last-prompt`, `cwd`, `gitBranch`, per-record `timestamp` |
| `sessions/<pid>.json` | **live registry**: `pid` ↔ `sessionId`, plus Claude's self-reported `status` (busy/idle/waiting) and `waitingFor` |
| `ide/<port>.lock` | SSE port → the editor's workspace path. Written by the Claude Code editor extension, so it's the same shape for VS Code, its forks and JetBrains. It also carries `ideName` (`vscode.env.appName`), which goes **unread** — `__CFBundleIdentifier` answers "which app" exactly, and for hosts that ship no extension at all |
| `projects/<slug>/<uuid>/subagents/agent-*.jsonl` | **usage only**: subagent transcripts. Invisible to the session scanner by design, mandatory for the cost scanner |

Usage additionally needs `message.usage` (all five token buckets plus `iterations`),
`requestId`, and `system/turn_duration`'s `durationMs`. There is **no cost field in the
transcript** — the old `costUSD` is gone — so the money is computed, never read.

Don't scan `projects/` recursively: one level deeper, `<uuid>/subagents/agent-*.jsonl`
holds subagent transcripts that would balloon the session count with false entries.

## Core design decisions

Each of these is the conclusion of a real measurement. Before changing one, read the
comments in the corresponding file (they carry the numbers).

- **Read only the last 64KB** — `projects/` measured at 723MB with a 37.5MB single
  file; parsing whole files is not viable. The tail already yields 93% of titles and
  72% of summaries.
- **Use the records' `timestamp`, not file mtime** — Claude Code rewrites trailing
  metadata records when you haven't touched a session; measured 71% of files with
  mtime 5+ minutes later than the last message (median 3.6h). mtime is only a coarse
  filter for "should this file be read at all".
- **State: registry first, guessing as fallback** — `sessions/<pid>.json` gives exact
  matches; only processes it misses (measured 1 of 6) fall back to "a project with N
  live processes matches its N most recent sessions". Never apply "this directory has
  a process" to every session in the directory — measured to inflate 11 into 56.
- **Closed terminal = the work is done** — `away_summary` is a snapshot, not state;
  treating it as a to-do source accumulates a scary, meaningless number. To revisit
  old sessions, use the resume list.
- **Three lines per row: title / `You` last-prompt / `Claude` away_summary** — the
  title only identifies the session; `last-prompt` (99% coverage) reminds you what
  you asked; `away_summary` (72%) is the actual next step. With no summary, leave it
  blank — don't fall back to last-prompt (printing the same sentence twice reads as
  a bug).
- **Live sessions must not be `--resume`d** — that spawns a second process for the
  same session. If it's alive, switch back to its original terminal window/tab.
- **Which app to jump to is `__CFBundleIdentifier`, never `TERM_PROGRAM`** — the env var that
  names the terminal cannot name the app. Cursor, Windsurf and VSCodium all report
  `TERM_PROGRAM=vscode`, so a jump keyed on that opens Visual Studio Code for someone sitting
  in Cursor; Zed's **ACP** agents report no `TERM_PROGRAM` at all and have no tty either
  (measured on a live `codex-acp` tree — Zed's agent panel spawns the adapter directly). What
  every one of them does carry is `__CFBundleIdentifier`, which launchd stamps on an .app and
  inherits down — measured present on Zed's terminal, VS Code's terminal and those ACP agents.
  `TerminalHost` therefore has one `.app(bundleID:name:port:)` case instead of a list of known
  editors, and `--dump` prints the id it resolved. The one host deliberately **given up on** is
  tmux: measured (3.5a) every pane reports `TERM_PROGRAM=tmux`, and the bundle id that survives
  is the *server's* birthplace — start the server from Zed, attach later from iTerm, and the
  panes still say Zed. Activating the wrong app confidently is worse than the Finder fallback.
- **Three tiers, by how precisely an app can be aimed at** — AppleScript reaches an individual
  *tab*, but only iTerm2 and Terminal have a dictionary (Zed ships no `.sdef`, so its terminal
  tab is simply out of reach). One tier down, `ide/<port>.lock` names the *workspace*, so the
  right window comes up. Below that, activate the app and hand it the folder. Jumping does the
  bare activation **and** the folder, both unconditionally: `open`'s exit status can't be used
  to tell them apart — measured `open -b com.apple.ActivityMonitor <folder>` exiting **0** while
  Activity Monitor never came to the front, so only an unknown bundle id ever fails. Folder
  last, so where it works the right window ends up on top.
- **Start at login keeps no UserDefaults copy** — `SMAppService` owns that state, and the
  user can switch it off in System Settings without the app hearing about it; a cached
  `true` would then contradict macOS. Read `status` every time, and re-read it whenever
  the settings tab appears.
- **The update check points at a release, it never installs one** — the standard answer is
  Sparkle, which is a third-party framework, an appcast, a second signing key and an installer
  helper. What's actually missing without one is much smaller: nobody quits a menu bar app, so
  a 0.1.0 user never finds out 0.2.0 exists. `UpdateCheck` reads `/releases/latest` (already
  excludes drafts and prereleases), compares two numbers, and opens the release page. Homebrew
  users get the real thing from `brew upgrade`.
- **Compare versions numerically, never as strings** — "0.10.0" sorts *before* "0.9.0"
  lexicographically, so the app would go silent exactly when it finally had news.
  `--update-check` prints the ordering table and flags the pairs string comparison gets wrong.
- **A badge, not a menu item** — the first version put both routes in a submenu off the "…"
  button: technically present, practically invisible. It's now an amber `UpdateBadge` in the
  main window's masthead, in the menu bar panel's footer next to "All", and in the settings
  About row, all opening one `UpdateSheet`. The badge wears `waitingChip`, the same amber as the
  session chips — it can't be mistaken for one, because those are a bare number and this one has
  the word on it. Compact ("Update") wherever it shares a line with other controls; the About row
  is the one place with room and the one place whose job is telling you which version is which,
  so there it reads "Update to 0.3.0".
- **The panel's badge routes through the main window** — `MenuBarExtra(.window)` is an `NSPanel`
  that closes the moment it loses key, which is exactly what a sheet or popover on top of it
  does. It sets `Navigation.showingUpdate` and opens the window, which is also where the same
  badge lives, so both roads reach one sheet.
- **Both update routes are offered, never guessed** — a cask-installed copy sits at exactly the
  same `/Applications` path as one dragged there by hand, so the app cannot tell which way it got
  there, and sending a `brew` user to a zip is worse than asking. The sheet has a primary
  Download button and `brew upgrade --cask your-turn` underneath. The command is printed rather
  than described ("Copy the brew command" is longer than the command) with a copy glyph on the
  right — without it the box reads as a code sample, and nobody clicks a code sample.
- **The published screenshots render with the badge off** — `--render --demo` seeds a pending
  release, and an "Update" badge in the README implies the app in the picture is stale. The
  main-window and usage frames get a deliberately empty second `UpdateCheck`; the badge and sheet
  get their own frames (`*-update.png`, `light-update-badge.png`, `light-update-panel.png`),
  same reasoning as `light-usage-month.png`.
- **Nothing about updates touches the menu bar badge** — the icon and its number answer one
  question, "how many sessions are waiting for you". A second meaning turns a glanceable count
  into something you have to stop and interpret. The notice lives in the "…" menu and the
  settings About row, and only exists when there's something to say — there is no
  "Check for Updates…" item and no "you're up to date" state anywhere in the UI.
- **The daily stamp is written only on success** — a failed request already can't repeat before
  the next launch (`checkedThisLaunch`), so stamping failures too would mean a laptop that was
  offline this morning stays quiet all day after the network comes back.
- **No "dismissed" flag** — the cached release is re-compared against the running version on
  every launch, so installing the update clears the notice by itself. Stored state that can
  disagree with what's actually installed is the same trap as `LaunchAtLogin`'s.
- **Palettes are data, not light/dark** — three palettes flow down via the `\.theme`
  environment value; views never check `colorScheme` themselves.
- **A pinned Dock icon needs `applicationShouldHandleReopen`** — `LSUIElement` means there's
  no Dock icon of our own; one only appears while a window is open, because
  `managesActivationPolicy()` flips the policy to `.regular`. Anyone who then picks "Keep in
  Dock" has a permanent icon for an app that usually has no windows, and clicking it does
  **nothing** by default: the app is already running, so there is nothing to launch. That
  hook is the only one that fires. `AppDelegate` handles it and calls `openWindow`, which it
  gets handed by the menu bar's label — measured: that label's `onAppear` fires once at
  launch, before any window exists, and it's the one piece of UI alive for the whole session
  (both windows can close, and the panel is only built when the menu is opened). Verified by
  `lsappinfo`: `UIElement` with no window → reopen → `Foreground`.
- **Full screen has to be handed back, and re-handed back** — `LSUIElement` also costs the
  window its green button. Measured: `collectionBehavior` settles at 131328, `.auxiliary` +
  `.fullScreenAuxiliary` with no `.fullScreenPrimary` — a window that may join someone else's
  full-screen space but can't own one, so the button is left with plain zoom. It isn't the
  activation policy at birth (promoting to `.regular` before `openWindow` measures the same
  131328), and it isn't a stamp that can be corrected once: AppKit rewrote the behavior three
  times in the first half-second, the last at ~0.4s, dropping the flag each time. So
  `allowsFullScreen()` re-asserts it from a KVO observer on `collectionBehavior` rather than
  from any fixed delay — verified to hold at 131456 across a close and reopen.
- **Every launch opens the window, login included** — one rule, no exceptions, chosen for
  consistency: the same gesture must not depend on whether the app happens to already be
  running, which is state the user can't see. The alternative (a window on a click but not at
  login) needs the app to tell those apart, and macOS only offers
  `NSApplicationLaunchIsDefaultLaunchKey` for it — whose click side measures `true`, but whose
  login side can't be reproduced without an actual logout, since `launchctl kickstart` refuses
  on `SMAppService` jobs. A rule that's right most of the time and unverifiable the rest is
  worth less than one that always holds. Reverting to "menu bar icon only on launch" is
  deleting the `claimLaunchWindow()` call in `MenuBarLabel`.
- **`claimLaunchWindow()` is a per-process one-shot, and has to be** — it's called from the
  menu bar label's `onAppear`, and that label's body re-evaluates on every scan as the badge
  count changes. Without the latch, "open the window at launch" would degrade into "open the
  window whenever a session changes state".

### The usage pipeline is a second pipeline, on purpose

Cost reconstruction disagrees with the session scanner on all three of the decisions
above, so `Stats/` never touches `Scanner/`. Verified end to end against `ccusage`
restricted to Claude models: **$6,193 vs $6,176 — 0.27%**, and per model +0.0%.

- **Read whole files, and descend into `subagents/`** — the exact opposite of both
  session-scanner rules, and both reversals are required. Measured: subagent
  transcripts hold 10,183 requests / 1.54G tokens, about a quarter of everything;
  skipping them undercounts the bill by that much. Cost: 594 files / 1.0GB in **1.5s**
  (release build, `concurrentPerform`), against 4.05s for the same work single-threaded.
- **`UsageCache` is what makes it affordable** — keyed on `(size, mtime)`, storing each
  file's parsed records. Warm rescan measured at **36ms**. Deliberately *not* resuming
  from a stored byte offset: Claude Code rewrites tail metadata records, so an offset
  can point into rewritten bytes and double-count money. A changed file is re-read whole
  (46MB worst case ≈ 150ms) and only ever for sessions you're actually using.
- **Deduplicate by `requestId`, and keep the row with the most output** — measured 51%
  of rows are duplicates, so not deduplicating nearly doubles the total. Which row wins
  matters too, and the source research got this wrong: it claims the rows are identical.
  Measured here, **16.5% of requests have `output_tokens` growing across their rows**
  (one goes 2 → 14,812) because the rows are progressive snapshots of a streaming
  response. Keeping the first undercounts output by 15% on `claude-opus-5` and **67% on
  `claude-sonnet-5`**. Input and cache counts are fixed at request start and really are
  identical — output is the only field that drifts.
- **Price per iteration, each at its own model** — when `usage.iterations` exists, the
  top-level `usage` silently omits `advisor_message` entries, which often ran on a
  different model. Rare (33 of 36,489 requests) but individually up to 92% off.
- **An unpriced model is `nil`, never `$0`** — measured 129 `<synthetic>` records. Both
  the CLI and the window name them and exclude them from the total. Quietly pricing
  unknown tokens at zero is the one failure an accounting tool can't come back from.
- **Group projects by git repository, not by folder name** — measured 126 distinct `cwd`
  values for 36 real projects, and 19 folder names covering more than one directory
  (three unrelated projects each have a `backend`). Keying on the name both fragments one
  project across three bars and merges three projects into one. `SessionResolver` still
  groups by exact `cwd` — that's what picks the right window to jump to.
- **The Usage tab scans on arrival, not on a timer** — `MainWindowPage` fires
  `StatsStore.loadIfNeeded()` when you switch to it, and that skips anything scanned in the
  last minute, so flipping tabs never costs the 30-second session refresh anything. The tab
  is deliberately not the default and its choice isn't persisted: the inbox is the product,
  and opening onto a spend page every morning would turn Your Turn into the monitor it was
  written not to be.
- **Which tab is showing lives in `Navigation`, not `@State`** — the menu bar's "Usage" item
  has to open the window *onto* that tab, and `.localized()` re-ids the whole subtree on a
  language switch, which would otherwise bounce you back to the session list mid-read.
- **The search field on the Usage and Settings tabs is faded and disabled, not removed** —
  taking it out of the stack pulls the tab picker up by the height of a text field, sliding the
  control you just clicked out from under the cursor.
- **Settings is a tab, not a window** — an app that lives in the menu bar and usually has no
  windows at all shouldn't answer a click by opening a second one. `Cmd-,` and the "…" menu's
  "Settings…" now set `Navigation.mode` and open the main window, the gear button is gone (two
  controls opening the same page, side by side, is one too many), and `SettingRow`'s label column
  went from 78pt to `Theme.gutter`, so all four tabs hang off one spine. The notes under each row
  are capped at 420pt: the old 560pt window enforced a readable measure by accident, and widening
  the page removed the constraint without removing the reason for it.
- **`PillPicker` and `UpdateBadge` never compress** — measured at the window's 720pt minimum with
  four tabs: the pills truncated to "By…", "By p…", "Us…", "Sett…", and once they were fixed the
  badge degraded through "Up…" to a bare arrow. Both carry `.fixedSize()`. The headline is the
  only thing in that row that may give, and it does — four lines at 720pt, two at the 860pt
  default. `--render` emits `light-narrow.png` at exactly 720 so that stays visible.

### The heatmap and the period filter

- **The heatmap is keyed on tokens, never dollars** — the squares encode *effort*, and
  pricing them would make the same day's work change shade whenever a model's rate moves or
  you switch from Opus to Haiku. Every dollar figure on the page lives outside the grid.
- **Quartiles, not a linear scale** — measured spread is 200–500M tokens a day with real
  outliers; on a linear ramp one huge day paints everything else in the palest shade. Same
  reason GitHub's graph isn't linear either.
- **A fixed 26-week grid, not one that grows with your history** — 14pt cells + 3pt gaps ×
  26 = 442pt, plus a 32pt weekday gutter. The window's 720pt minimum leaves 492pt of content
  once the page gutter and inset are out, so it fills the row at the narrowest size and never
  scrolls sideways. A grid sized to the data would resize the whole row every Monday. Days
  before you first ran Claude Code really did cost nothing, so drawing them empty is accurate.
- **The heatmap draws `overall`; everything else draws `summary`** — it's the filter's
  control surface (click a square to select its month or week, unselected weeks fade to 0.28),
  and a navigator that only shows where you already are can't navigate.
- **Filtering re-aggregates, it doesn't filter `byDay`** — a month's project ranking is a
  different question from the sum of its days, so `UsageStats.build` takes a range and
  `byProject` / `byModel` / `rhythm` are rebuilt inside it. The scan is retained in
  `StatsStore`, so switching months costs one in-memory pass and no disk access. It runs off
  the main actor and cancels its predecessor: holding an arrow down steps through months
  faster than a 37,000-record pass finishes, and every month in between is already stale.
- **The three tiles change meaning under a filter** — today / this week / this month answers
  "how am I doing right now", which is not a question March has. Filtered, they become
  total / per active day / busiest day, and "per active day" divides by the days you actually
  worked: a week's spend over 7 calendar days describes nobody's week.
- **`--render` emits an extra `light-usage-month.png`** — the filtered layout differs in
  three places at once (the stepper appears, the tiles change, the grid dims), and none of it
  shows up in a screenshot of the default state. `loadDemo` takes a scan rather than a
  finished summary so the demo runs through the real pricing, aggregation **and** filter.
- **`turn_duration.messageCount` is unused** — measured average 489.6 per turn, which
  can't mean "messages in this turn". Not shown until someone pins down what it is.

### Three `ImageRenderer` pitfalls (for `--render`)

- It doesn't expand `ScrollView` content → any scrollable page must be split into a
  standalone view (`MainWindowPage` / `SettingsPage`)
- It can't render `LazyVStack` either → always use `VStack`
- AppKit-backed controls (`TextField`, `Picker`, `Button`) render as a yellow
  prohibition sign → artifact only, the real app is fine, but it ruins a published
  screenshot. `--render` sets `\.isOffscreenRender`, and those views swap in a
  plain-SwiftUI stand-in showing the same value. `PillPicker` is the same idea one
  step earlier: it replaced a native `Picker` outright.

## Localization

English is the source language, 繁體中文 the translation, and the app follows the system
language by default. Anything else falls back to English.

**The in-app override** (Settings → Language: Follow System / English / 繁體中文) is stored in
`AppPreferences.language` and pushed into `Localization.override`, which recomputes the
`.lproj` bundle on the spot — CFBundle reads the *system's* language list, so an override can
only work because `Localization` does the match itself. Switching is live: `L()` is a plain
function, so no view depends on it, and `.localized(preferences)` (applied at the root of both
scenes) reads the `@Observable` preference and re-`id`s the subtree, which is the one
lever that re-runs every `body` underneath. `.managesActivationPolicy()` sits *outside* that
scope on purpose — its open/close counter must not read the rebuild as "the last window
closed". Cost: `@State` below the scope resets (the main window's search text and grouping).

**Adding a string:** wrap it in `L("the English text")` and add that same text as a key to
**both** `Resources/en.lproj/Localizable.strings` and `Resources/zh-Hant.lproj/Localizable.strings`.
Keys are the English sentence itself, so a missed lookup degrades to readable English rather
than to `settings.archive.empty`. Interpolation carries over — `L("\(count) resumable")` looks
up `"%lld resumable"` (`%@` for strings); a `.strings` file with the wrong specifier prints
garbage, so check both files agree.

**What is deliberately *not* localized:**

- CLI output — `--dump` / `--triage` / `--next` / `--render` are developer verification tools;
  English keeps their columns and grep patterns stable. `SessionState.label` and
  `DumpCommand.relative` exist only for those and stay English.
- `SummaryText`'s bilingual marker lists ("下一步", "Next:", …) — those match against Claude's
  own writing, so they're data, not UI.
- Product names (VS Code / iTerm2 / Terminal / Zed), SF Symbol names, UserDefaults keys, and
  `MainWindow.Mode.rawValue` (it's the `Identifiable` id — translating it would make the
  selection identity move with the system language).

`Session.displayTitle`'s `(Untitled)` and `ResolvedSession.actionLine` are UI strings that also
reach `--dump`, so a Chinese machine sees those two translated in the dump. Accepted: an
English placeholder sitting inside a Chinese window is the more visible defect.

### Packaging gotchas (why `bundle.sh` does what it does)

- **`swift build` does not compile `.xcstrings`** — measured: it copies the String Catalog into
  the resource bundle verbatim, `Bundle.localizations` reports only `en`, and every string
  resolves to its key. String Catalogs need Xcode's build system. Hence plain `.lproj/*.strings`.
- **The resource bundle has to be copied into the .app** — SwiftPM emits
  `YourTurn_YourTurn.bundle` next to the binary. Copy only the binary and `Bundle.module` finds
  no `.lproj` at all.
- **The .app needs its own `en.lproj` / `zh-Hant.lproj`** — measured: CFBundle clamps every
  sub-bundle to the localizations the *main* bundle declares, so an .app without `zh-Hant.lproj`
  pins the resource bundle to English no matter what's inside it. Those folders also carry
  `InfoPlist.strings`, which is the only way to translate `NSAppleEventsUsageDescription` (macOS
  reads it from the main bundle).
- **`Localization.swift` matches the language itself** rather than handing `Bundle.module`
  straight to `String(localized:)`. Same clamp: a raw `swift build` binary declares no
  localizations, so `--render` could never produce a Chinese screenshot. Matching
  `Locale.preferredLanguages` by hand behaves identically in both. It also has to read the
  `.lproj` name back from `preferredLocalizations` — SwiftPM copies `zh-Hant.lproj` out
  lowercased as `zh-hant.lproj`.

**Verifying:** `--render <dir> --demo -language <tag>` is the reliable form —  UserDefaults'
argument domain feeds `AppPreferences.language` directly, without touching the real setting on
disk, which is also the only way to prove the *override* works rather than the system language.
`-AppleLanguages '(…)'` exercises the system-language path instead, but **it can't override a
stored preference**: once Settings → Language is set to anything but Follow System, that wins,
and a machine with the preference pinned to zh-Hant renders Chinese no matter what
`-AppleLanguages` says.

`docs/screenshots/` stays English. The main-window and usage shots are rendered with
`-language en`; the `*-settings.png` ones are **deliberately not regenerated that way**,
because the language pill would then show "English" selected instead of the "Follow System"
a new user actually sees. Regenerate those only on a machine whose system language is English
and whose preference is still Follow System.

## Conventions

- Comments state **why** plus the **measured numbers**, never what the code does
- A change isn't done until verified with `--dump` or `--render`
- Every user-visible string goes through `L("…")` and lands in both `.lproj` files
