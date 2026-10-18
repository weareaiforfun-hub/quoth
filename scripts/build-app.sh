#!/bin/bash
# Builds Quoth.app (no Xcode needed) and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Quoth
swift build -c release --product quoth-mcp
BIN="$(swift build -c release --show-bin-path)/Quoth"
MCP="$(swift build -c release --show-bin-path)/quoth-mcp"
APP="build/Quoth.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Quoth"
cp "$MCP" "$APP/Contents/MacOS/quoth-mcp"
cp Sources/Quoth/Resources/Info.plist "$APP/Contents/Info.plist"
cp Sources/Quoth/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Model Lab inputs: test sentences and speech samples.
cp Evals/cleanup-golden.jsonl "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/Samples"
cp Evals/samples/*.wav Evals/samples/samples.json "$APP/Contents/Resources/Samples/"

# A stable signing identity keeps macOS permission grants across rebuilds.
# Ad-hoc signatures change every build, so Accessibility/Input Monitoring would reset.
IDENTITY="Quoth Dev"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --deep --sign "$IDENTITY" --identifier app.quoth "$APP"
else
  echo "warning: no 'Quoth Dev' certificate found (run scripts/setup.sh); signing ad-hoc." >&2
  codesign --force --deep --sign - --identifier app.quoth "$APP"
fi

DEST="$HOME/Applications/Quoth.app"
mkdir -p "$HOME/Applications"
pkill -x Quoth 2>/dev/null && sleep 0.5 || true
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "Installed $DEST"
[ "${1:-}" = "--open" ] && open "$DEST"
exit 0
