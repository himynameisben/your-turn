# Your Turn

**An inbox for your Claude Code sessions — and a record of where your tokens went.**

You're running three, five, eight Claude Code sessions in parallel — and *you* are
now the bottleneck. Your Turn sits in the macOS menu bar and answers four questions:
**which sessions are open? which one is waiting for me? where did it stop, and what's
next? and which projects have been eating my tokens?**

It runs no LLM, reads no conversation, and treats `~/.claude` as read-only.

English | [繁體中文](README.zh-TW.md)

![Your Turn main window](docs/screenshots/light.png)

## Whose turn is it?

Most Claude Code menu bar apps show a status light. Your Turn tracks something
narrower and more useful: **whose turn it is**. A session that's running doesn't need
you. A session that finished is done. The only thing worth a badge is a session that
stopped and is waiting for your reply — and for that one, you want to know *what it
said last*, not just that a light turned amber.

Each session shows three lines:

1. **The title** — enough to recognize which session this is
2. **You** — the last thing you asked it to do
3. **Claude** — its own summary of where it stopped and what happens next

Click it, and Your Turn jumps you back to the exact place the session lives: the
right VS Code window, the right iTerm2 tab, the right Terminal window. Finished
sessions reopen with `claude --resume` in a fresh terminal.

## What have you been busy with?

![The Usage tab](docs/screenshots/light-usage.png)

The Usage tab answers the thing you can't reconstruct from memory: **which projects
actually took your week, and which one burned the most tokens.** Pick a month or a
week and the whole page re-scopes to it — the project ranking, the model split, and
how much of the day each of you spent waiting on the other.

Claude Code records token counts in its transcripts but no cost, so Your Turn works it
out from
[LiteLLM's public price table](https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json).
Cross-checked against `ccusage`, the total lands within 0.3%.

### A contribution graph, for tokens

![Scoped to one month](docs/screenshots/light-usage-month.png)

One square per day, shaded by how hard you leaned on Claude that day. Click a square,
or step with the arrows, to scope the page to that month or week.

## Features

- **Menu bar badge that only counts what needs you** — running sessions don't ring
- **One line per session** in the menu bar panel; a full window with search and
  by-time / by-project grouping when you want the overview
- **Jump back to the exact window** — VS Code, iTerm2, and Terminal.app supported
- **Star** the projects you care about, **archive** what you don't
- **Usage tab** — which projects took the week, by tokens and by cost, with a heatmap
  and month / week filters
- **Start at login** — one switch in Settings, registered as a real macOS login item
- **Three hand-tuned palettes** (light / dim / dark) — palettes are data, not a
  dark-mode toggle
- **English and 繁體中文** — follows your system language, or pick one in Settings and
  the whole app switches over on the spot
- **Zero dependencies** — pure Swift 6 / SwiftUI, no third-party packages

## Privacy

Your Turn is a **reader**. Claude Code already writes everything it needs into
`~/.claude`; this app just reads it.

- **Read-only** on `~/.claude` — it never writes there
- The inbox reads only the **last 64KB** of each session file. The Usage tab reads
  whole files, but only counts token numbers — it still never looks at what you or
  Claude actually said
- **No telemetry, no LLM calls** — nothing about you ever leaves your Mac
- **One outbound request, and only if you open the Usage tab**: a plain GET for
  LiteLLM's public price table, so new models don't show up unpriced. It sends nothing
  but the request itself, and a trimmed copy ships inside the app so the numbers work
  with the network off
- Preferences (stars, archive, appearance) live in UserDefaults / Application
  Support
- Open source — audit it yourself

The only permission it asks for is Apple Events (to switch your terminal back to a
session's window), and macOS prompts you before granting it.

## Install

**Requirements:** macOS 15+, [Claude Code](https://claude.com/claude-code)

- **Download** the signed & notarized app from [Releases](../../releases), unzip,
  and drag it to Applications.
- **Build from source:**

  ```bash
  git clone https://github.com/himynameisben/your-turn.git && cd your-turn
  ./Scripts/bundle.sh release
  open build/YourTurn.app
  ```

  The app stays in `build/`, and the icon appears in the menu bar.

  If you'd rather have it in `/Applications`, `./Scripts/install.sh` does the same
  build and then quits any running copy, replaces `/Applications/YourTurn.app`, and
  launches it. Re-run that line to upgrade in place — and use it for the copy you
  actually live with, since "start at login" registers whatever bundle path it was
  switched on from, and one armed from `build/` breaks when that directory is wiped.

- Homebrew cask: planned.

## How it works

Everything comes from files Claude Code already maintains under `~/.claude`:

| Path | What it provides |
|---|---|
| `projects/<slug>/<uuid>.jsonl` | session title, your last prompt, Claude's away summary, timestamps, and the token counts for every request |
| `projects/<slug>/<uuid>/subagents/*.jsonl` | the same, for everything a session fanned out to |
| `sessions/<pid>.json` | live registry: which process runs which session, and its status |
| `ide/<port>.lock` | which VS Code window a session belongs to |

The interesting engineering decisions — why tail-64KB, why mtime lies, how live
processes are matched to sessions, and why the same `requestId` can report different
token counts on different lines — are documented with measured numbers in
[CLAUDE.md](CLAUDE.md) and the source comments.

Screenshots on this page are rendered from invented data with
`YourTurn --render <dir> --demo`, never from a real scan.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The short version: keep it a reader, keep
it dependency-free, and verify changes with the built-in `--dump` / `--cost` /
`--render` tools.

## License

[MIT](LICENSE)
