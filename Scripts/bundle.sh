#!/bin/bash
# Assemble the SPM binary into a runnable .app bundle.
#
# MenuBarExtra only works correctly inside a real app bundle, and LSUIElement
# (no Dock icon, no Cmd-Tab entry) can only be set via Info.plist.
#
#   ./Scripts/bundle.sh            # debug
#   ./Scripts/bundle.sh release    # release
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/YourTurn.app"
VERSION="${VERSION:-0.4.0}"

cd "$ROOT"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/YourTurn" "$APP/Contents/MacOS/YourTurn"

# SPM compiles Sources/YourTurn/Resources into a bundle of its own. Copying the binary alone
# leaves Bundle.module with no .lproj to read, and every UI string renders as its English key.
cp -R "$BIN_DIR/YourTurn_YourTurn.bundle" "$APP/Contents/Resources/"

# Build the app icon from the checked-in 1024px source. Finder and Applications use the
# multi-resolution .icns in the main bundle; keeping one PNG as the source avoids committing
# ten mechanically resized copies.
ICON_SOURCE="$ROOT/Assets/AppIcon.png"
ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SOURCE" \
        --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double_size=$((size * 2))
    sips -z "$double_size" "$double_size" "$ICON_SOURCE" \
        --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# The .app needs its own <lang>.lproj folders on top of that, for two separate reasons:
#   1. macOS reads NSAppleEventsUsageDescription's translation from the *main* bundle only.
#   2. CFBundle clamps every sub-bundle to the localizations the main bundle declares — an
#      .app with no zh-Hant.lproj would pin YourTurn_YourTurn.bundle to English.
# (Localization.swift also matches the language itself so the raw `swift build` binary can
# still render Chinese, but the .app should declare its languages the ordinary way.)
for lproj in "$ROOT"/Sources/YourTurn/Resources/*.lproj; do
    mkdir -p "$APP/Contents/Resources/$(basename "$lproj")"
    cp "$lproj/InfoPlist.strings" "$APP/Contents/Resources/$(basename "$lproj")/"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>YourTurn</string>
    <key>CFBundleIdentifier</key><string>tw.lychee.yourturn</string>
    <key>CFBundleName</key><string>Your Turn</string>
    <key>CFBundleDisplayName</key><string>Your Turn</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon.icns</string>
    <!-- Source language. Anything the user's system asks for that isn't listed in
         Contents/Resources/*.lproj falls back to this one. -->
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <!-- Pure menu bar app: no Dock icon, no Cmd-Tab entry -->
    <key>LSUIElement</key><true/>
    <!-- "Jump back to its window" drives iTerm / Terminal via Apple Events;
         macOS shows this string the first time it asks for permission -->
    <key>NSAppleEventsUsageDescription</key>
    <string>Your Turn needs to control your terminal to switch you back to the window and tab where a Claude Code session lives.</string>
</dict>
</plist>
PLIST

# Ad-hoc signing is enough for local development. Release builds are signed
# with a Developer ID certificate and notarized — see Scripts/release.sh.
#
# stderr is deliberately not redirected: codesign reports both its result and its
# failures there, so `2>/dev/null` left `set -e` aborting the script with no message
# at all — the one moment the reason matters.
codesign --force --sign - "$APP"

echo "✅ $APP"
