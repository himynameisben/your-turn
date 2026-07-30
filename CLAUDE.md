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
| `--login-item [on\|off]` | Read or flip the "start at login" registration. Only meaningful from the binary **inside** the .app (`/Applications/YourTurn.app/Contents/MacOS/YourTurn`) — `SMAppService` answers for the bundle it runs in, and there's no other way to check: these registrations don't show up in AppleScript's login-item list, and the system's database needs root |
| `--render <dir> [--demo]` | Offscreen-render the main window and settings page to PNGs in every palette. `--demo` renders invented sessions instead of the real scan — **required for anything published**, since a real scan puts your own titles, prompts and summaries in the picture |

**Data-layer changes: run `--dump`. Layout changes: run `--render`.** Layout cannot
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
│   └── ProcessProbe.swift      pgrep/lsof/ps to find live claude processes and their terminals
├── Model/                      judgment and state
│   ├── Session.swift           a single session and its state (running/awaiting/finished)
│   ├── SessionResolver.swift   session × process × registry → ProjectGroup
│   ├── SessionStore.swift      @Observable, the UI's single source of truth
│   ├── SummaryText.swift       extracts the "next step" sentence from away_summary
│   ├── AppPreferences.swift    terminal / editor / appearance / language preferences
│   └── LaunchAtLogin.swift     start-at-login, via SMAppService — state lives in macOS, not UserDefaults
├── Actions/
│   ├── SessionActions.swift    jump back to the original window, resume, open editor (AppleScript)
│   ├── PinStore.swift          starred projects (UserDefaults key remains pinnedProjects)
│   └── ArchiveStore.swift      archiving
├── UI/
│   ├── MenuBarPanel.swift      menu bar panel, one line per session
│   ├── MainWindow.swift        main window, three lines per row (title / You / Claude)
│   ├── SettingsWindow.swift    settings
│   ├── Theme.swift             three palettes + type scale, passed via the \.theme environment value
│   ├── Components.swift        PillPicker, activation policy
│   ├── Localization.swift      the `L("…")` helper, `AppLanguage`, and the live-switch scope
│   └── RenderCommand.swift     implementation of --render, plus the --demo fake sessions
└── Resources/
    ├── en.lproj/               Localizable.strings (source language) + InfoPlist.strings
    └── zh-Hant.lproj/          the same two files, translated

docs/RELEASING.md               signing & notarization playbook
```

## Data sources (all inside `~/.claude`)

| Path | What it provides |
|---|---|
| `projects/<slug>/<uuid>.jsonl` | the session itself: `ai-title`, `away_summary`, `last-prompt`, `cwd`, `gitBranch`, per-record `timestamp` |
| `sessions/<pid>.json` | **live registry**: `pid` ↔ `sessionId`, plus Claude's self-reported `status` (busy/idle/waiting) and `waitingFor` |
| `ide/<port>.lock` | SSE port → VS Code workspace path |

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
- **Start at login keeps no UserDefaults copy** — `SMAppService` owns that state, and the
  user can switch it off in System Settings without the app hearing about it; a cached
  `true` would then contradict macOS. Read `status` every time, and re-read it whenever
  the settings window appears.
- **Palettes are data, not light/dark** — three palettes flow down via the `\.theme`
  environment value; views never check `colorScheme` themselves.

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
function, so no view depends on it, and `.localized(preferences)` (applied at the root of all
three scenes) reads the `@Observable` preference and re-`id`s the subtree, which is the one
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

**Verifying:** `--render <dir> --demo` for English, the same command plus
`-AppleLanguages '(zh-Hant)'` to exercise the system-language path. To exercise the *override*
instead, append `-language zh-Hant` — UserDefaults' argument domain feeds the preference
directly without touching the real one on disk, which is the only way to prove the setting
works rather than the system language. `docs/screenshots/` stays English (rendered with the
preference left on Follow System, so the pill shown is the default a new user sees).

## Conventions

- Comments state **why** plus the **measured numbers**, never what the code does
- A change isn't done until verified with `--dump` or `--render`
- Every user-visible string goes through `L("…")` and lands in both `.lproj` files
