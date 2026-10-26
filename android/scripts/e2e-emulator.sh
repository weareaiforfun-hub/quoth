#!/bin/bash
# End-to-end check of the Quoth keyboard on a running emulator, or a phone with USB debugging (unlocked, screen on):
# installs the debug APK, enables the keyboard, then dictates `say`-generated speech into the
# setup screen's "Try it here" box through the debug-input hook, and checks the text that lands.
#
# Usage: scripts/e2e-emulator.sh [path/to/ggml-base.bin]
#   The model is pushed once if the app doesn't have it yet (default: the Mac app's copy).
# Start a headless emulator first, so nothing takes over the screen:
#   $ANDROID_HOME/emulator/emulator -avd quoth-test -no-window -no-audio &
set -euo pipefail
cd "$(dirname "$0")/.."

ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
ADB="$ANDROID_HOME/platform-tools/adb"
APK=app/build/outputs/apk/debug/app-debug.apk
PKG=app.quoth
MODEL="${1:-$HOME/Library/Application Support/Quoth/models/ggml-base.bin}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT

"$ADB" wait-for-device
"$ADB" install -r "$APK" >/dev/null
"$ADB" shell pm grant "$PKG" android.permission.RECORD_AUDIO
if ! "$ADB" shell run-as "$PKG" ls files/models/ggml-base.bin >/dev/null 2>&1; then
  echo "Pushing speech model…"
  "$ADB" push -q "$MODEL" /data/local/tmp/ggml-base.bin
  "$ADB" shell run-as "$PKG" mkdir -p files/models
  "$ADB" shell run-as "$PKG" cp /data/local/tmp/ggml-base.bin files/models/ggml-base.bin
  "$ADB" shell rm /data/local/tmp/ggml-base.bin
fi

# ui.py: dump the screen, tap nodes by text/description, read the text box.
cat > "$WORK/ui.py" <<'PY'
import re, subprocess, sys
ADB = sys.argv[1]
def dump():
    subprocess.run([ADB, "shell", "uiautomator", "dump", "/sdcard/ui.xml"], capture_output=True)
    return subprocess.run([ADB, "shell", "cat", "/sdcard/ui.xml"], capture_output=True, text=True).stdout
def nodes():
    return re.findall(r'<node [^>]*?text="([^"]*)"[^>]*?class="([^"]*)"[^>]*?content-desc="([^"]*)"[^>]*?bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', dump())
cmd = sys.argv[2]
if cmd == "focus":   # tap the try-it box
    for t, cls, d, a, b, c, e in nodes():
        if cls == "android.widget.EditText":
            subprocess.run([ADB, "shell", "input", "tap", str((int(a)+int(c))//2), str((int(b)+int(e))//2)]); break
elif cmd == "text":  # print the try-it box's text (empty when only the hint shows)
    import html
    for t, cls, d, *_ in nodes():
        if cls == "android.widget.EditText":
            print("" if t.startswith("Tap here, then tap") else html.unescape(t)); break
PY
ui() { python3 -I "$WORK/ui.py" "$ADB" "$@"; }

# The mic button lives in the keyboard window, which uiautomator doesn't dump: find it from the keyboard's bounds.
mic_xy() {
  "$ADB" shell dumpsys window InputMethod | python3 -I -c '
import re, sys
s = sys.stdin.read()
m = re.search(r"mFrame=\[(\d+),(\d+)\]\[(\d+),(\d+)\]", s) or re.search(r"frame=\[(\d+),(\d+)\]\[(\d+),(\d+)\]", s)
l, t, r, b = map(int, m.groups())
print((l + r) // 2, b - (b - t) * 45 // 100)'
}

dictate() { # text-to-speak, expected substring ("" = expect nothing inserted)
  say -o "$WORK/in.aiff" "$1"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$WORK/in.aiff" "$WORK/in.wav"
  "$ADB" push -q "$WORK/in.wav" /data/local/tmp/in.wav
  "$ADB" shell run-as "$PKG" cp /data/local/tmp/in.wav files/debug-input.wav
  "$ADB" logcat -c
  read -r x y < <(mic_xy)
  "$ADB" shell input tap "$x" "$y"; sleep 1; "$ADB" shell input tap "$x" "$y"
  for _ in $(seq 1 60); do
    "$ADB" logcat -d -s Quoth | grep -qE "inserted|Didn|failed|nothing" && break
    "$ADB" logcat -d -s Quoth | grep -q "timing" && sleep 1 && break
    sleep 1
  done
  "$ADB" logcat -d -s Quoth | grep -oE "timing.*" || true
}

pass=0; fail=0
check() { # name, expected (exact)
  local got; got="$(ui text)"
  if [ "$got" = "$2" ]; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; echo "  expected: $2"; echo "  got:      $got"; fail=$((fail+1)); fi
}

# Force-stopping a keyboard makes Android fall back to another one, so select Quoth afterwards.
"$ADB" shell am force-stop "$PKG"
"$ADB" shell ime enable "$PKG/.android.QuothKeyboardService" >/dev/null
"$ADB" shell ime set "$PKG/.android.QuothKeyboardService" >/dev/null
"$ADB" shell am start -n "$PKG/.android.MainActivity" >/dev/null
sleep 3
ui focus; sleep 2

dictate "Hi Sam, the meeting moved to Thursday at three. Could you bring the slides?"
check "sentence" "Hi Sam, the meeting moved to Thursday at 3. Could you bring the slides?"

dictate "see you there"
check "appends with a space" "Hi Sam, the meeting moved to Thursday at 3. Could you bring the slides? See you there."

# With the cleanup model installed: the repeated words go (golden case filler-3).
if "$ADB" shell run-as "$PKG" ls files/models/ | grep -q '\.gguf'; then
  dictate "can we can we move the call to tomorrow"
  check "cleanup removes repeats" "Hi Sam, the meeting moved to Thursday at 3. Could you bring the slides? See you there. Can we move the call to tomorrow?"
fi

# Silence: whisper says [BLANK_AUDIO] or a stock phrase; nothing should be inserted.
"$ADB" shell run-as "$PKG" rm -f files/debug-input.wav
before_silence="$(ui text)"
python3 -I -c "
import struct, wave
w = wave.open('$WORK/silence.wav', 'wb'); w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
w.writeframes(struct.pack('<h', 0) * 32000); w.close()"
"$ADB" push -q "$WORK/silence.wav" /data/local/tmp/in.wav
"$ADB" shell run-as "$PKG" cp /data/local/tmp/in.wav files/debug-input.wav
"$ADB" logcat -c
read -r x y < <(mic_xy)
"$ADB" shell input tap "$x" "$y"; sleep 1; "$ADB" shell input tap "$x" "$y"; sleep 8
check "silence inserts nothing" "$before_silence"

# Password box (the setup screen's debug-only password extra): the mic is off, so nothing is inserted.
"$ADB" push -q "$WORK/in.wav" /data/local/tmp/in.wav
"$ADB" shell run-as "$PKG" cp /data/local/tmp/in.wav files/debug-input.wav
"$ADB" shell am start -f 0x10008000 -n "$PKG/.android.MainActivity" --ez password true >/dev/null
sleep 3
ui focus; sleep 2
"$ADB" logcat -c
read -r x y < <(mic_xy)
"$ADB" shell input tap "$x" "$y"; sleep 1; "$ADB" shell input tap "$x" "$y"; sleep 5
if "$ADB" logcat -d -s Quoth | grep -q timing; then echo "FAIL password box (it transcribed)"; fail=$((fail+1)); else check "password box inserts nothing" ""; fi

"$ADB" shell run-as "$PKG" rm -f files/debug-input.wav
"$ADB" shell rm -f /data/local/tmp/in.wav
echo "e2e: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
