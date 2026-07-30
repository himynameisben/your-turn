#!/bin/bash
# Build, sign, notarize, and staple a distributable YourTurn-<version>.zip.
#
# Local usage (after `xcrun notarytool store-credentials`):
#   SIGN_IDENTITY="Developer ID Application: Company (TEAMID)" \
#   NOTARY_PROFILE=yourturn ./Scripts/release.sh 0.2.0
#
# CI usage (App Store Connect API key instead of a keychain profile):
#   SIGN_IDENTITY=... NOTARY_KEY_PATH=key.p8 NOTARY_KEY_ID=... \
#   NOTARY_ISSUER_ID=... ./Scripts/release.sh 0.2.0
set -euo pipefail

VERSION="${1:?usage: Scripts/release.sh <version>}"
: "${SIGN_IDENTITY:?set SIGN_IDENTITY to your Developer ID Application identity}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$VERSION" ./Scripts/bundle.sh release

# Work on an isolated copy: build/YourTurn.app is shared with dev workflows, and a
# concurrent bundle.sh during the notarization wait re-signs it ad-hoc — the staple
# then fails with "Record not found" because the on-disk cdhash no longer matches
# the ticket (this actually happened on the first release).
STAGING="dist/release-$VERSION"
APP="$STAGING/YourTurn.app"
ZIP="dist/YourTurn-$VERSION.zip"
rm -rf "$STAGING" "$ZIP"
mkdir -p "$STAGING"
ditto "build/YourTurn.app" "$APP"

# Hardened runtime + secure timestamp are both required for notarization.
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
else
    : "${NOTARY_KEY_PATH:?set NOTARY_PROFILE, or NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER_ID}"
    xcrun notarytool submit "$ZIP" \
        --key "$NOTARY_KEY_PATH" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER_ID:?}" \
        --wait
fi

# The ticket can lag the "Accepted" status by a minute or two while it propagates
# to Apple's CDN — "Record not found" here usually just means "too early".
for attempt in 1 2 3 4 5 6 7 8; do
    if xcrun stapler staple "$APP"; then break; fi
    if [[ "$attempt" == 8 ]]; then echo "stapling failed after $attempt attempts" >&2; exit 65; fi
    echo "ticket not available yet, retrying in 20s ($attempt/8)…"
    sleep 20
done

# Re-zip so the download contains the stapled ticket and works offline.
ditto -c -k --keepParent "$APP" "$ZIP"

# Final check: Gatekeeper should accept it as Notarized Developer ID.
spctl -a -vv "$APP"
echo "✅ $ZIP"
