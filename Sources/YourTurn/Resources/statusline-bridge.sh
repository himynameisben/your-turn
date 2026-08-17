#!/bin/sh
#
# Your Turn's status-line bridge.
#
# Claude Code hands its status line command the session JSON on stdin, and that JSON is the
# only place a subscription's rate limits ever appear: measured, nothing under ~/.claude
# carries them — `projects/*.jsonl` plus `cache/`, `telemetry/`, `daemon/`, `jobs/` and
# `session-env/` were all searched for `five_hour` / `seven_day` / `rate_limit` and came back
# empty. So there is no file to read instead, and this script exists to make one.
#
# Installed and removed from Your Turn's settings page. Edits here are overwritten the next
# time that switch is flipped.

set -u

payload=$(cat)
dir="$HOME/Library/Application Support/YourTurn"
out="$dir/claude-allowance.json"

# `plutil` rather than jq or python3: it ships with every macOS, it is a real JSON parser
# rather than a regex over someone else's braces, and it measured 10.7ms per call — this runs
# on a 300ms debounce, so that budget matters. jq isn't guaranteed to be installed and
# /usr/bin/python3 can trigger the Command Line Tools installer on a machine without them.
#
# One call lifts the whole subtree. A missing `rate_limits` exits non-zero, which is exactly
# the "not known yet" signal: measured, the key is absent on every render before the session's
# first API response, and absent altogether for anyone not on a Claude.ai subscription.
#
# Read through the exit status, never through emptiness: measured, `-extract … raw` prints its
# "no value at that key path" complaint on **stdout**, so a missing key otherwise arrives
# looking like a value and lands in the file.
if limits=$(printf '%s' "$payload" | /usr/bin/plutil -extract rate_limits json -o - - 2>/dev/null); then
    mkdir -p "$dir"
    # Written beside the real file and moved into place, so a reader never catches half of it.
    printf '{"observed_at":%s,"rate_limits":%s}\n' "$(date +%s)" "$limits" >"$out.new" &&
        mv -f "$out.new" "$out"
fi

# Chain first if there was already a status line here. Claude Code gives the command exactly
# one, so replacing someone's line without asking is the one way this could do real damage.
if [ "$#" -gt 0 ] && [ -n "$1" ]; then
    printf '%s' "$payload" | eval "$1"
    exit $?
fi

# Nothing to chain, so print our own. Documented behaviour: configuring *any* status line makes
# Claude Code drop most of its footer hints (`esc to interrupt`, `? for shortcuts`, the voice
# hint). Printing a blank line would trade those away for nothing at all.
field() {
    if value=$(printf '%s' "$payload" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null); then
        printf '%s' "$value"
    fi
}
pct() {
    value=$(field "$1")
    # `used_percentage` arrives as a float (measured `82.500000`), and a status line has no
    # room for six decimals.
    [ -n "$value" ] && printf '%.0f' "$value"
}

line=""
add() { [ -n "$1" ] && line="${line:+$line · }$1"; }

add "$(field model.display_name)"
workspace=$(field workspace.current_dir)
[ -n "$workspace" ] && add "$(basename "$workspace")"
five=$(pct rate_limits.five_hour.used_percentage)
[ -n "$five" ] && add "5h $((100 - five))% left"
week=$(pct rate_limits.seven_day.used_percentage)
[ -n "$week" ] && add "week $((100 - week))% left"

printf '%s\n' "$line"
