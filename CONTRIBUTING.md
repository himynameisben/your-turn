# Contributing

Thanks for helping make Your Turn better. A few things to know before you start.

## Ground rules

These are the product principles every change has to respect:

- **Your Turn is a reader.** It never writes to `~/.claude`, never talks to the
  network, and never runs an LLM. Preferences live in UserDefaults / Application
  Support. If a feature needs to break one of these, open an issue first.
- **Zero dependencies.** Pure Swift / SwiftUI, no third-party packages.
- **Comments explain *why*, with measured numbers.** Most non-obvious decisions in
  this codebase (tail-read size, timestamp handling, process matching) came from
  measurements against real `~/.claude` data. Keep that style; don't write comments
  that restate the code.
- **Every UI string is localized.** Wrap it in `L("…")` and add the key to *both*
  `Sources/YourTurn/Resources/en.lproj/Localizable.strings` and
  `zh-Hant.lproj/Localizable.strings` — a key present in only one language ships as
  raw English to the other. CLI output (`--dump` and friends) stays English.

## Building

```bash
swift build                # compile
./Scripts/bundle.sh        # assemble build/YourTurn.app (debug)
open build/YourTurn.app    # the icon appears in the menu bar
```

`MenuBarExtra` and `LSUIElement` both require a real app bundle — running the raw
binary won't work.

## Verifying changes

The binary has CLI entry points that print results without opening any UI:

| Command | Purpose |
|---|---|
| `--dump` | Print every session: state, times, your last prompt / Claude's next step, jump target, stats |
| `--triage` | Cross-check how far "terminal still open" and "has pending work" diverge |
| `--next` | Quality stats for next-step extraction (pending / clear / unknown ratio) |
| `--cost` | Print the usage pipeline: scan timings, dedup counts, total spend, per model / project / day, rhythm. `--no-cache` forces a cold scan; `--refresh-prices` fires the LiteLLM download |
| `--render <dir>` | Render the main window (all three tabs) and settings page to PNGs in every palette |

Add `--demo` to `--render` for invented sessions and invented usage instead of your
real `~/.claude` — required for anything you attach to a PR, since a real scan puts
your own project names and actual spend in the picture. To check the Chinese build,
append `-language zh-Hant` to the same command.

**Session-layer changes: verify with `--dump`. Usage-layer changes: verify with
`--cost`. Layout changes: verify with `--render`.**
Layout can't be eyeballed from code — `--render` is the only reliable way to see the
result (`LSUIElement` windows can't be captured with `screencapture`).

A change isn't done until it's been verified with one of these.

## Pull requests

- Keep changes minimal and focused; simplicity beats cleverness here.
- Include the relevant `--dump` / `--cost` / `--render` evidence in the PR description.
- CI must pass (`swift build` + bundle on macOS 15).
