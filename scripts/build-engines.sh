#!/bin/bash
# Builds the speech and text engines that ship inside Quoth.app, from pinned source:
#   whisper-server (whisper.cpp) and llama-server (llama.cpp), both MIT-licensed.
# Output: build/engines/{whisper-server,llama-server,licenses/}
#
# The binaries are fully static apart from macOS system frameworks (Metal, Accelerate…),
# with the Metal shaders embedded, so they run on any Apple Silicon Mac without Homebrew.
# Needs git and cmake (brew install cmake). Re-running reuses the checkouts and only rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

WHISPER_TAG="v1.9.5"
LLAMA_TAG="v0.7.0"

SRC="build/engine-src"
OUT="build/engines"
mkdir -p "$SRC" "$OUT/licenses"

fetch() { # repo tag dir
  if [ ! -d "$3/.git" ]; then
    git clone --quiet --depth 1 --branch "$2" "$1" "$3"
  elif [ "$(git -C "$3" describe --tags --exact-match 2>/dev/null)" != "$2" ]; then
    git -C "$3" fetch --quiet --depth 1 origin tag "$2"
    git -C "$3" checkout --quiet "$2"
  fi
}

# Shared ggml options: static, Metal with embedded shaders, Accelerate for BLAS,
# and a CPU baseline every Apple Silicon chip supports (M1 and later).
GGML_OPTS=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_OSX_ARCHITECTURES=arm64
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
  -DBUILD_SHARED_LIBS=OFF
  -DGGML_METAL=ON
  -DGGML_METAL_EMBED_LIBRARY=ON
  -DGGML_BLAS=ON
  -DGGML_NATIVE=OFF
  -DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16
)
JOBS="$(sysctl -n hw.ncpu)"

fetch https://github.com/ggml-org/whisper.cpp "$WHISPER_TAG" "$SRC/whisper.cpp"
cmake -S "$SRC/whisper.cpp" -B "$SRC/whisper.cpp/build" "${GGML_OPTS[@]}" \
  -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_SDL2=OFF -DWHISPER_CURL=OFF >/dev/null
cmake --build "$SRC/whisper.cpp/build" --target whisper-server -j "$JOBS" >/dev/null

fetch https://github.com/ggml-org/llama.cpp "$LLAMA_TAG" "$SRC/llama.cpp"
cmake -S "$SRC/llama.cpp" -B "$SRC/llama.cpp/build" "${GGML_OPTS[@]}" \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=ON -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF >/dev/null
cmake --build "$SRC/llama.cpp/build" --target llama-server -j "$JOBS" >/dev/null

cp -f "$SRC/whisper.cpp/build/bin/whisper-server" "$SRC/llama.cpp/build/bin/llama-server" "$OUT/"
strip -x "$OUT/whisper-server" "$OUT/llama-server"

# Licence notices for everything compiled into the binaries.
cp -f "$SRC/whisper.cpp/LICENSE" "$OUT/licenses/whisper.cpp-LICENSE.txt"
cp -f "$SRC/llama.cpp/LICENSE" "$OUT/licenses/llama.cpp-LICENSE.txt"
cp -f "$SRC/llama.cpp/licenses/LICENSE-jsonhpp" "$OUT/licenses/nlohmann-json-LICENSE.txt"
cp -f "$SRC/llama.cpp/vendor/cpp-httplib/LICENSE" "$OUT/licenses/cpp-httplib-LICENSE.txt"
cat > "$OUT/licenses/README.txt" <<NOTICE
Quoth ships two engines built from source:
  whisper-server from whisper.cpp $WHISPER_TAG (MIT), https://github.com/ggml-org/whisper.cpp
  llama-server from llama.cpp $LLAMA_TAG (MIT), https://github.com/ggml-org/llama.cpp
Both include ggml (MIT, same licence files), nlohmann/json (MIT) and cpp-httplib (MIT).
llama-server also includes stb_image (public domain / MIT), miniaudio (public domain / MIT-0)
and sheredom/subprocess.h (Unlicense), which require no notice.
NOTICE
printf 'whisper.cpp %s\nllama.cpp %s\n' "$WHISPER_TAG" "$LLAMA_TAG" > "$OUT/VERSIONS.txt"

# Refuse to ship anything that links outside macOS itself (e.g. Homebrew dylibs).
for bin in "$OUT/whisper-server" "$OUT/llama-server"; do
  bad="$(otool -L "$bin" | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/Library/)' || true)"
  if [ -n "$bad" ]; then echo "error: $bin links non-system libraries:" >&2; echo "$bad" >&2; exit 1; fi
done
echo "Built $OUT: $(cat "$OUT/VERSIONS.txt" | tr '\n' ' ')"
