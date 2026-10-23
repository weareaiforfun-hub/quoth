#!/bin/bash
# Fetches Sparkle's command-line tools (generate_keys, sign_update) into build/sparkle/bin,
# pinned to the same version as Package.swift and checked against its SHA-256.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="2.10.0"
SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
DIR="build/sparkle"

if [ ! -x "$DIR/bin/sign_update" ] || [ "$(cat "$DIR/VERSION" 2>/dev/null)" != "$VERSION" ]; then
  rm -rf "$DIR"
  mkdir -p "$DIR"
  curl -sSL --fail -o "$DIR/sparkle.tar.xz" "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz"
  echo "$SHA256  $DIR/sparkle.tar.xz" | shasum -a 256 -c --quiet
  tar -xJf "$DIR/sparkle.tar.xz" -C "$DIR" bin
  rm "$DIR/sparkle.tar.xz"
  echo "$VERSION" > "$DIR/VERSION"
fi
echo "$DIR/bin"
