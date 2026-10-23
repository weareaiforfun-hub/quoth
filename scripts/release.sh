#!/bin/bash
# Builds a release on the maintainer's Mac: build/release/Quoth-<version>.dmg (+ .sha256).
#   scripts/release.sh 0.4.0
#
# Every release MUST be signed with the same "Quoth Dev" certificate: macOS ties users' permission
# grants (Accessibility, Input Monitoring, Microphone) to it, and a different certificate would
# silently break them on update. This script refuses any other certificate.
# It also signs the DMG for Sparkle (automatic updates) with the EdDSA key in the keychain and writes
# build/release/appcast.xml, which is attached to the GitHub release.
# Publishing is a separate, manual step (printed at the end).
# Testing only: SPARKLE_PUBLIC_KEY + SPARKLE_KEY_FILE use a throwaway update key, QUOTH_BUILD a build
# number, DOWNLOAD_BASE another download location, ALLOW_DIRTY=1 skips the clean-tree check.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: scripts/release.sh X.Y.Z" >&2; exit 1; }

IDENTITY="Quoth Dev"
# SHA-1 of the project's signing certificate (public; the private key stays in the maintainer's keychain).
CERT_SHA1="CA876DC71337A6245EBD3D36CB300388BCC88A77"

fail() { echo "error: $*" >&2; exit 1; }

# 1. The right certificate, and a clean, committed tree (a release must match a commit).
actual="$(security find-certificate -c "$IDENTITY" -Z 2>/dev/null | awk '/SHA-1 hash:/ {print $3}')"
[ -n "$actual" ] || fail "no '$IDENTITY' certificate in the keychain. Restore it from the backup; never create a new one for releases."
[ "$actual" = "$CERT_SHA1" ] || fail "'$IDENTITY' certificate is $actual, expected $CERT_SHA1. A different certificate would break every user's permissions."
[ -n "${ALLOW_DIRTY:-}" ] || [ -z "$(git status --porcelain)" ] || fail "uncommitted changes; commit them first so the release matches a commit."
SPARKLE_BIN="$(scripts/sparkle-tools.sh)"

# 2. Tests, then the app (engines from pinned source, version stamped, signed).
scripts/test.sh >/dev/null || fail "unit tests failed"
scripts/build-engines.sh
QUOTH_VERSION="$VERSION" scripts/build-app.sh --no-install
APP="build/Quoth.app"

# 3. Check the signature: valid, sealed, and tied to the pinned certificate.
codesign --verify --strict --deep "$APP"
codesign -d -r- "$APP" 2>&1 | grep -qi "certificate leaf = H\"$CERT_SHA1\"" || fail "app is not signed with the pinned certificate"
for helper in Quoth quoth-mcp whisper-server llama-server; do
  codesign -d -r- "$APP/Contents/MacOS/$helper" 2>&1 | grep -qi "$CERT_SHA1" || fail "$helper is not signed with the pinned certificate"
done
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
[ "$(plist CFBundleShortVersionString)" = "$VERSION" ] || fail "version not stamped"
[ -n "$(plist SUPublicEDKey)" ] || fail "SUPublicEDKey is empty in Info.plist: without it, users of this release could never update automatically. See docs/releasing.md."
codesign --verify --strict "$APP/Contents/Frameworks/Sparkle.framework" || fail "Sparkle isn't signed"

# 4. The disk image: the app next to an Applications shortcut, for drag-to-install.
OUT="build/release"
DMG="$OUT/Quoth-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$OUT"
rm -f "$DMG" "$DMG.sha256"
ditto "$APP" "$STAGE/Quoth.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Quoth" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG"
hdiutil verify -quiet "$DMG"
(cd "$OUT" && shasum -a 256 "Quoth-$VERSION.dmg" > "Quoth-$VERSION.dmg.sha256")

# 5. Sparkle: sign the DMG with the update key and write the appcast (just this release).
if [ -n "${SPARKLE_KEY_FILE:-}" ]; then KEY=(--ed-key-file "$SPARKLE_KEY_FILE"); else KEY=(--account app.quoth); fi
SIG="$("$SPARKLE_BIN/sign_update" "${KEY[@]}" "$DMG")" || fail "sign_update failed (is the update key in the keychain? see docs/releasing.md)"
# The signature must verify against the public key inside the app, or nobody could install this update.
swift scripts/verify-update-signature.swift "$DMG" "$(echo "$SIG" | sed -E 's/.*edSignature="([^"]+)".*/\1/')" "$(plist SUPublicEDKey)" >/dev/null \
  || fail "the DMG's update signature doesn't match the app's SUPublicEDKey"
BASE="${DOWNLOAD_BASE:-https://github.com/weareaiforfun-hub/quoth/releases/download/v$VERSION}"
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Quoth</title>
    <item>
      <title>Quoth $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$(plist CFBundleVersion)</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/weareaiforfun-hub/quoth/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <enclosure url="$BASE/Quoth-$VERSION.dmg" $SIG type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
xmllint --noout "$OUT/appcast.xml"

echo
echo "Built $DMG ($(du -h "$DMG" | cut -f1)), $(cut -d' ' -f1 "$DMG.sha256")"
echo "Test it on a Mac (or user account) without Quoth, then publish:"
echo "  git tag v$VERSION && git push origin v$VERSION"
echo "  gh release create v$VERSION $DMG $DMG.sha256 $OUT/appcast.xml --title \"Quoth $VERSION\" --notes-file docs/release-notes.md"
