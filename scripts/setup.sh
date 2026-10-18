#!/bin/bash
# One-time setup: speech engine, models, and a local code-signing identity.
set -euo pipefail

MODEL_DIR="$HOME/Library/Application Support/Quoth/models"
WHISPER_MODEL="ggml-large-v3-turbo-q5_0.bin"
RAM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
# Pick the cleanup model by memory (override with CLEANUP_MODEL=…). See docs/models.md.
if [ "$RAM_GB" -ge 32 ]; then DEFAULT_MODEL="qwen2.5:14b-instruct"
elif [ "$RAM_GB" -ge 16 ]; then DEFAULT_MODEL="qwen2.5:7b-instruct"
else DEFAULT_MODEL="qwen2.5:3b-instruct"; fi
CLEANUP_MODEL="${CLEANUP_MODEL:-$DEFAULT_MODEL}"
SETTINGS="$HOME/Library/Application Support/Quoth/settings.json"

if [ "$(uname -m)" != "arm64" ]; then
  echo "warning: Quoth is built for Apple Silicon; on Intel Macs local models will be slow." >&2
fi

echo "==> whisper.cpp"
command -v whisper-server >/dev/null || brew install whisper-cpp

echo "==> Whisper model ($WHISPER_MODEL, ~575 MB)"
mkdir -p "$MODEL_DIR"
if [ ! -f "$MODEL_DIR/$WHISPER_MODEL" ]; then
  curl -L --fail -o "$MODEL_DIR/$WHISPER_MODEL.part" \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$WHISPER_MODEL"
  mv "$MODEL_DIR/$WHISPER_MODEL.part" "$MODEL_DIR/$WHISPER_MODEL"
fi

echo "==> Ollama cleanup model ($CLEANUP_MODEL)"
command -v ollama >/dev/null || brew install ollama
pgrep -x ollama >/dev/null || (brew services start ollama || (ollama serve >/dev/null 2>&1 &)) 
sleep 1
ollama pull "$CLEANUP_MODEL"
# Tell the app which model was installed (only on first setup, never overwriting your settings).
if [ ! -f "$SETTINGS" ]; then
  mkdir -p "$(dirname "$SETTINGS")"
  printf '{\n  "ollamaModel" : "%s"\n}\n' "$CLEANUP_MODEL" > "$SETTINGS"
fi
echo "Cleanup model: $CLEANUP_MODEL (${RAM_GB} GB RAM detected)"

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
