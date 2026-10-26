#!/bin/bash
# Fetches the pinned engine sources that the Android app compiles with the NDK.
# whisper.cpp and llama.cpp (both MIT) go to third_party/, which git ignores. Re-running is a no-op.
set -euo pipefail
cd "$(dirname "$0")/.."

WHISPER_TAG="v1.9.5"
LLAMA_TAG="v0.7.0"   # the same tags as the Mac app (scripts/build-engines.sh)

fetch() { # repo tag dir
  if [ ! -d "$3/.git" ]; then
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$2" "$1" "$3"
  elif [ "$(git -C "$3" describe --tags --exact-match 2>/dev/null)" != "$2" ]; then
    git -C "$3" fetch --quiet --depth 1 origin tag "$2"
    git -C "$3" checkout --quiet "$2"
  fi
}

mkdir -p third_party
fetch https://github.com/ggml-org/whisper.cpp "$WHISPER_TAG" third_party/whisper.cpp
fetch https://github.com/ggml-org/llama.cpp "$LLAMA_TAG" third_party/llama.cpp
echo "whisper.cpp $WHISPER_TAG and llama.cpp $LLAMA_TAG in third_party/"
