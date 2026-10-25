#!/bin/bash
# Scores an on-device cleanup model on the golden evals (Evals/cleanup-golden.jsonl), on a phone or emulator:
# pushes the GGUF (once) and the cases, runs them through LlamaEngine in a debug build, and prints the
# per-case lines and the summary. Outputs also go to eval-<model>.tsv for comparing with `:core:eval`.
#
# Usage: scripts/eval-device.sh path/to/model.gguf     (ANDROID_SERIAL picks the device when several are connected)
# The model must be one of ModelCatalog.cleanup. Keep the phone unlocked with the screen on.
set -euo pipefail
cd "$(dirname "$0")/.."

ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
ADB="$ANDROID_HOME/platform-tools/adb"
PKG=app.quoth
MODEL="$1"
NAME="$(basename "$MODEL")"

push() { "$ADB" push -q "$1" /data/local/tmp/quoth-push && "$ADB" shell run-as "$PKG" cp /data/local/tmp/quoth-push "$2" && "$ADB" shell rm /data/local/tmp/quoth-push; }

"$ADB" install -r app/build/outputs/apk/debug/app-debug.apk >/dev/null
"$ADB" shell run-as "$PKG" mkdir -p files/models
if [ "$("$ADB" shell run-as "$PKG" stat -c %s "files/models/$NAME" 2>/dev/null | tr -d '\r')" != "$(stat -f %z "$MODEL")" ]; then
  echo "Pushing $NAME…"
  push "$MODEL" "files/models/$NAME"
fi
push ../Evals/cleanup-golden.jsonl files/cleanup-golden.jsonl
printf %s "$NAME" > /tmp/quoth-dcm.$$ && push /tmp/quoth-dcm.$$ files/debug-cleanup-model && rm /tmp/quoth-dcm.$$

"$ADB" shell am force-stop "$PKG"
"$ADB" logcat -c
"$ADB" shell am start -n "$PKG/.android.MainActivity" --ez evals true >/dev/null
for _ in $(seq 1 600); do
  "$ADB" logcat -d -s Quoth | grep -qE "eval done|eval: no|dictation failed" && break
  "$ADB" logcat -d -s AndroidRuntime | grep -q FATAL && break
  sleep 2
done
"$ADB" logcat -d -s Quoth QuothLlama AndroidRuntime | grep -E "loaded|FATAL" || true
"$ADB" logcat -d -s Quoth | sed -n 's/.*Quoth *: //p' | grep -E "^eval" > "eval-${NAME%.gguf}.log" || true
python3 -I -c 'import sys,re
for l in open(sys.argv[1], encoding="utf-8"):
    m = re.match(r"^eval \S+ (\S+) \d+ms.*? \| (.*)$", l.rstrip("\n"))
    if m: print(m[1] + "\t" + m[2])' "eval-${NAME%.gguf}.log" > "eval-${NAME%.gguf}.tsv"
cat "eval-${NAME%.gguf}.log"
"$ADB" logcat -d -s QuothLlama | grep timing | tail -3
"$ADB" shell run-as "$PKG" rm -f files/cleanup-golden.jsonl files/debug-cleanup-model
