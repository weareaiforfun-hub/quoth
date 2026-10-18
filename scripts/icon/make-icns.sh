#!/bin/bash
# Builds Sources/Quoth/Resources/AppIcon.icns from the chosen concept (default: 5, "Accent dot").
#   scripts/icon/make-icns.sh [concept-number]
set -euo pipefail
cd "$(dirname "$0")/../.."
N="${1:-5}"
TMP="$(mktemp -d)"
swift scripts/icon/render-icons.swift "$TMP" "$N" >/dev/null
SRC="$TMP/concept-$N.png"
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$SRC" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$SRC" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Sources/Quoth/Resources/AppIcon.icns
cp "$SRC" Sources/Quoth/Resources/AppIcon-1024.png
rm -rf "$TMP"
echo "Wrote Sources/Quoth/Resources/AppIcon.icns (concept $N)"
