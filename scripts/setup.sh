#!/bin/bash
# One-time setup for building Quoth from source: build tools, models, and a local code-signing identity.
# The engines (whisper.cpp, llama.cpp) are built from pinned source by scripts/build-engines.sh.
set -euo pipefail

MODEL_DIR="$HOME/Library/Application Support/Quoth/models"
RAM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
# Same bundles as the app's Setup page (ModelBundle): Whisper Small on 8 GB Macs, Turbo above.
if [ "$RAM_GB" -ge 16 ]; then WHISPER_MODEL="ggml-large-v3-turbo-q5_0.bin"; else WHISPER_MODEL="ggml-small.bin"; fi
# Pick the language model by memory. See docs/models.md and ModelCatalog.gguf.
# Columns: file, Hugging Face repo, SHA-256.
if [ "$RAM_GB" -ge 32 ]; then
  LLM=(Qwen2.5-14B-Instruct-Q4_K_M.gguf bartowski/Qwen2.5-14B-Instruct-GGUF e47ad95dad6ff848b431053b375adb5d39321290ea2c638682577dafca87c008)
elif [ "$RAM_GB" -ge 16 ]; then
  LLM=(Qwen2.5-7B-Instruct-Q4_K_M.gguf bartowski/Qwen2.5-7B-Instruct-GGUF 65b8fcd92af6b4fefa935c625d1ac27ea29dcb6ee14589c55a8f115ceaaa1423)
else
  LLM=(Qwen_Qwen3-4B-Instruct-2507-Q4_K_M.gguf bartowski/Qwen_Qwen3-4B-Instruct-2507-GGUF 2fde00ce69dd4899c70d020845e2638353015bba0fdf161b3eb965f2bca4464e)
fi
SETTINGS="$HOME/Library/Application Support/Quoth/settings.json"

if [ "$(uname -m)" != "arm64" ]; then
  echo "warning: Quoth is built for Apple Silicon; on Intel Macs local models will be slow." >&2
fi

echo "==> Build tools (cmake, for the engines)"
command -v cmake >/dev/null || brew install cmake

echo "==> Whisper model ($WHISPER_MODEL)"
mkdir -p "$MODEL_DIR"
if [ ! -f "$MODEL_DIR/$WHISPER_MODEL" ]; then
  curl -L --fail -o "$MODEL_DIR/$WHISPER_MODEL.part" \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$WHISPER_MODEL"
  mv "$MODEL_DIR/$WHISPER_MODEL.part" "$MODEL_DIR/$WHISPER_MODEL"
fi

echo "==> Language model (${LLM[0]}, for ${RAM_GB} GB RAM)"
if [ ! -f "$MODEL_DIR/${LLM[0]}" ]; then
  curl -L --fail -C - -o "$MODEL_DIR/${LLM[0]}.part" "https://huggingface.co/${LLM[1]}/resolve/main/${LLM[0]}"
  echo "${LLM[2]}  $MODEL_DIR/${LLM[0]}.part" | shasum -a 256 -c --quiet
  mv "$MODEL_DIR/${LLM[0]}.part" "$MODEL_DIR/${LLM[0]}"
fi
# Tell the app which model was installed (only on first setup, never overwriting your settings).
if [ ! -f "$SETTINGS" ]; then
  mkdir -p "$(dirname "$SETTINGS")"
  printf '{\n  "localTextEngine" : "builtIn",\n  "llamaModelPath" : "%s",\n  "whisperModelPath" : "%s"\n}\n' "$MODEL_DIR/${LLM[0]}" "$MODEL_DIR/$WHISPER_MODEL" > "$SETTINGS"
fi

echo "==> Code-signing identity 'Quoth Dev'"
# A self-signed certificate gives the app a stable identity, so macOS keeps
# its Microphone/Accessibility/Input Monitoring grants across rebuilds.
if security find-certificate -c "Quoth Dev" >/dev/null 2>&1; then
  echo "already present"
else
  TMP="$(mktemp -d)"
  cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Quoth Dev
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout pass:quoth -name "Quoth Dev"
  security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P quoth -T /usr/bin/codesign
  rm -rf "$TMP"
  echo "created (if macOS asks whether codesign may use the key, choose Always Allow)"
fi

echo
echo "Done. Now run: scripts/build-app.sh --open"
