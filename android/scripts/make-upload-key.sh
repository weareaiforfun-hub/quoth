#!/bin/bash
# Creates Quoth's Google Play upload key: ~/.quoth/quoth-upload.jks, with its password in the macOS Keychain
# (item "quoth-upload"), where the release build finds it. Nothing is written to a plain file.
# Run it yourself in Terminal; it asks for a new password. See docs/android-release.md.
set -euo pipefail
DIR="$HOME/.quoth"
KEY="$DIR/quoth-upload.jks"
KEYTOOL=/opt/homebrew/opt/openjdk@17/bin/keytool
REPO="$(cd "$(dirname "$0")/../.." && pwd)"

mkdir -p "$DIR"; chmod 700 "$DIR"

# Old files from the first try: a key, and password files (which shouldn't exist at all).
old=()
[ -e "$KEY" ] && old+=("$KEY")
for f in "$DIR/android-signing.properties" "$REPO/android-signing.properties" "$REPO/android/android-signing.properties"; do
  [ -e "$f" ] && old+=("$f")
done
if [ ${#old[@]} -gt 0 ]; then
  echo "These files from an earlier try will be deleted:"
  printf '  %s\n' "${old[@]}"
  echo "Only do this if you have never uploaded anything to Google Play with that key."
  read -r -p "Delete them? (y/N) " ok
  [ "$ok" = y ] || [ "$ok" = Y ] || { echo "Nothing changed."; exit 1; }
  rm -f "${old[@]}"
fi

echo
echo "Choose a NEW password for the upload key: at least 12 characters, not used anywhere else."
echo "Save it in your password manager now; it can't be recovered. (Nothing shows while you type.)"
while true; do
  read -r -s -p "Password: " pw; echo
  read -r -s -p "Again: " pw2; echo
  if [ "$pw" != "$pw2" ]; then echo "They don't match. Try again."; continue; fi
  if [ ${#pw} -lt 12 ]; then echo "At least 12 characters, please."; continue; fi
  break
done
unset pw2

QUOTH_PW="$pw" "$KEYTOOL" -genkeypair -storetype PKCS12 -keystore "$KEY" -alias quoth-upload \
  -keyalg RSA -keysize 4096 -validity 10000 -dname "CN=Quoth" -storepass:env QUOTH_PW >/dev/null 2>&1 \
  || { echo "keytool failed"; exit 1; }
chmod 600 "$KEY"
# -U updates the Keychain item if an earlier run made one.
security add-generic-password -U -s quoth-upload -a quoth -l "Quoth upload key (Android)" -w "$pw"
unset pw QUOTH_PW

echo
echo "Done. The key is $KEY and its password is in your Keychain as \"quoth-upload\"."
echo "Last step: back up the key off this Mac. Attach quoth-upload.jks to the password entry"
echo "in your password manager (or copy it to an encrypted USB stick). Opening the folder now…"
open "$DIR"
