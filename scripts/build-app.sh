#!/bin/bash
# Builds Quoth.app (no Xcode needed) and installs it to ~/Applications.
#   scripts/build-app.sh                # build and install
#   scripts/build-app.sh --open         # …and launch it
#   scripts/build-app.sh --no-install   # only build/Quoth.app (used by release.sh)
# QUOTH_VERSION=0.4.0 stamps that version (and the commit count as build number) into the app.
set -euo pipefail
cd "$(dirname "$0")/.."

# The speech and text engines, built once from pinned source (a few minutes the first time).
[ -x build/engines/whisper-server ] && [ -x build/engines/llama-server ] || scripts/build-engines.sh

swift build -c release --product Quoth
swift build -c release --product quoth-mcp
BIN="$(swift build -c release --show-bin-path)/Quoth"
MCP="$(swift build -c release --show-bin-path)/quoth-mcp"
APP="build/Quoth.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Quoth"
# Sparkle (automatic updates) lives in Contents/Frameworks.
mkdir -p "$APP/Contents/Frameworks"
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Quoth"
cp "$MCP" "$APP/Contents/MacOS/quoth-mcp"
cp build/engines/whisper-server build/engines/llama-server "$APP/Contents/MacOS/"
mkdir -p "$APP/Contents/Resources/Licenses"
cp build/engines/licenses/* build/engines/VERSIONS.txt "$APP/Contents/Resources/Licenses/"
cp Sources/Quoth/Resources/Info.plist "$APP/Contents/Info.plist"
if [ -n "${QUOTH_VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $QUOTH_VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${QUOTH_BUILD:-$(git rev-list --count HEAD)}" "$APP/Contents/Info.plist"
fi
# Testing only: another update key or feed than the ones in Info.plist.
[ -n "${SPARKLE_PUBLIC_KEY:-}" ] && /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SPARKLE_PUBLIC_KEY" "$APP/Contents/Info.plist"
cp Sources/Quoth/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Model Lab inputs: test sentences and speech samples.
cp Evals/cleanup-golden.jsonl "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/Samples"
cp Evals/samples/*.wav Evals/samples/samples.json "$APP/Contents/Resources/Samples/"

# A stable signing identity keeps macOS permission grants across rebuilds.
# Ad-hoc signatures change every build, so Accessibility/Input Monitoring would reset.
IDENTITY="Quoth Dev"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  SIGN="$IDENTITY"
else
  echo "warning: no 'Quoth Dev' certificate found (run scripts/setup.sh); signing ad-hoc." >&2
  SIGN="-"
fi
# Inside out: Sparkle's helpers (as Sparkle documents), then ours, then the app around them.
SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign --force --sign "$SIGN" "$SPK/XPCServices/Installer.xpc"
codesign --force --sign "$SIGN" --preserve-metadata=entitlements "$SPK/XPCServices/Downloader.xpc"
codesign --force --sign "$SIGN" "$SPK/Autoupdate"
codesign --force --sign "$SIGN" "$SPK/Updater.app"
codesign --force --sign "$SIGN" "$APP/Contents/Frameworks/Sparkle.framework"
for helper in quoth-mcp whisper-server llama-server; do
  codesign --force --sign "$SIGN" --identifier "app.quoth.$helper" "$APP/Contents/MacOS/$helper"
done
codesign --force --sign "$SIGN" --identifier app.quoth "$APP"
codesign --verify --strict --deep "$APP"

[ "${1:-}" = "--no-install" ] && exit 0

DEST="$HOME/Applications/Quoth.app"
mkdir -p "$HOME/Applications"
pkill -x Quoth 2>/dev/null && sleep 0.5 || true
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "Installed $DEST"
[ "${1:-}" = "--open" ] && open "$DEST"
exit 0
