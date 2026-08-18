#!/bin/bash
# Build a release .app and install it into /Applications, replacing what's there.
#
#   ./Scripts/install.sh          # whatever version bundle.sh defaults to
#   ./Scripts/install.sh 0.4.0    # stamp a specific version into Info.plist
#   DEST=~/Applications/YourTurn.app ./Scripts/install.sh
#
# This is the "put it on my own Mac" path: an ad-hoc signature is all a bundle that
# never gets downloaded needs. To hand it to someone else, use Scripts/release.sh —
# Developer ID signing plus notarization.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${DEST:-/Applications/YourTurn.app}"
cd "$ROOT"

# Left empty when not given, so the single default in bundle.sh applies — a second
# copy of the version number here silently overrode it once already.
VERSION="${1:-${VERSION:-}}" ./Scripts/bundle.sh release

# Quit first, and wait for it to actually be gone. Copying over a running .app leaves
# the live process pointing at a bundle that no longer exists: the menu bar icon stays
# up, still running the old code, which is the worst possible way to test a change.
if pgrep -x YourTurn >/dev/null; then
    pkill -x YourTurn || true
    for _ in $(seq 30); do
        pgrep -x YourTurn >/dev/null || break
        sleep 0.1
    done
fi

rm -rf "$DEST"
cp -R "$ROOT/build/YourTurn.app" "$DEST"
open "$DEST"

# "Start at login" needs no saving and restoring around the swap: measured — the
# SMAppService registration is keyed to the bundle path, and a rebuilt bundle carrying
# a fresh ad-hoc signature into the same place still reports `enabled`. Printed anyway,
# because a login item quietly pointing at a stale path is exactly the kind of thing
# you'd rather find out here than at your next reboot.
echo "✅ $DEST"
echo "   $("$DEST/Contents/MacOS/YourTurn" --login-item)"
