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
    # Never read a stale dump: delete it first, and stop if a fresh one can't be made.
    subprocess.run([ADB, "shell", "rm", "-f", "/sdcard/ui.xml"], capture_output=True)
    out = subprocess.run([ADB, "shell", "uiautomator", "dump", "/sdcard/ui.xml"], capture_output=True, text=True).stdout
    if "dumped" not in out:
        sys.exit("uiautomator can't read the screen (" + out.strip() + "); restarting the device fixes a stuck one")
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
ui() { python3 -I "$WORK/ui.py" "$ADB" "$@" || { echo "STOP: can't read the screen"; exit 1; }; }

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
check() { # name, expected (exact), [another accepted text]
  local got; got="$(ui text)"
  if [ "$got" = "$2" ] || { [ -n "${3:-}" ] && [ "$got" = "$3" ]; }; then echo "PASS $1"; pass=$((pass+1))
  else echo "FAIL $1"; echo "  expected: $2"; echo "  got:      $got"; fail=$((fail+1)); fi
}

# A test dictionary (the user's own personal.json and history.json are put back at the end). Written while the app is stopped,
# because the app keeps it in memory.
"$ADB" shell am force-stop "$PKG"
# History is put back too, so the test dictations don't stay in the user's History.
had_personal=false; had_history=false
if "$ADB" shell run-as "$PKG" ls files/personal.json >/dev/null 2>&1; then
  had_personal=true
  "$ADB" shell run-as "$PKG" cp files/personal.json files/personal.json.e2e-backup
fi
if "$ADB" shell run-as "$PKG" ls files/history.json >/dev/null 2>&1; then
  had_history=true
  "$ADB" shell run-as "$PKG" cp files/history.json files/history.json.e2e-backup
fi
printf '%s' '{"dictionary":[{"id":"E2E-1","kind":"replacement","phrase":"cube control","replacement":"kubectl"}]}' > "$WORK/personal.json"
"$ADB" push -q "$WORK/personal.json" /data/local/tmp/personal.json
"$ADB" shell run-as "$PKG" cp /data/local/tmp/personal.json files/personal.json
"$ADB" shell rm /data/local/tmp/personal.json
restore_personal() {
  "$ADB" shell am force-stop "$PKG"
  "$ADB" shell run-as "$PKG" rm -f files/personal.json files/history.json
  if $had_personal; then "$ADB" shell run-as "$PKG" mv files/personal.json.e2e-backup files/personal.json; fi
  if $had_history; then "$ADB" shell run-as "$PKG" mv files/history.json.e2e-backup files/history.json; fi
}
trap 'restore_personal; rm -rf "${WORK:?}"' EXIT

# Force-stopping a keyboard makes Android fall back to another one, so select Quoth afterwards.
"$ADB" shell ime enable "$PKG/.android.QuothKeyboardService" >/dev/null
"$ADB" shell ime set "$PKG/.android.QuothKeyboardService" >/dev/null
"$ADB" shell am start -n "$PKG/.android.MainActivity" >/dev/null
sleep 3
ui focus; sleep 2

dictate "Hi Sam, the meeting moved to Thursday at three. Could you bring the slides?"
# The cleanup model may write the time as "3" or "3:00"; both are right.
check "sentence" "Hi Sam, the meeting moved to Thursday at 3. Could you bring the slides?" \
  "Hi Sam, the meeting moved to Thursday at 3:00. Could you bring the slides?"

dictate "see you there"
check "appends with a space" "Hi Sam, the meeting moved to Thursday at 3. Could you bring the slides? See you there." \
  "Hi Sam, the meeting moved to Thursday at 3:00. Could you bring the slides? See you there."

# A dictionary replacement: "cube control" is written as "kubectl".
before="$(ui text)"
dictate "run cube control get pods"
added="$(ui text)"; added="${added#"$before"}"
if [[ "$added" == *kubectl* && "$added" != *"cube control"* ]]; then echo "PASS dictionary replacement"; pass=$((pass+1))
else echo "FAIL dictionary replacement"; echo "  got: $added"; fail=$((fail+1)); fi

# With the cleanup model installed: a spoken correction is applied (golden case backtrack-1). Whisper keeps
# "actually", so only cleanup can turn this into "5 pm".
if "$ADB" shell run-as "$PKG" ls files/models/ | grep -q '\.gguf'; then
  before="$(ui text)"
  dictate "let's meet at four, actually five p m"
  added="$(ui text)"; added="${added#"$before"}"
  if [[ "$added" == *5* && "$added" != *4* && "$added" != *[Aa]ctually* ]]; then echo "PASS cleanup applies a correction ($added)"; pass=$((pass+1))
  else echo "FAIL cleanup applies a correction"; echo "  got: $added"; fail=$((fail+1)); fi
fi

# Auto-learn. Respells the name Quoth just wrote, the way a user fixes it, and expects the new spelling in
# the Dictionary. respell: replaces the last word ending in "$1" (any case) with "$2", typing at the end of the field.
respell() {
  local t; t="$(ui text)"
  read -r dels rest < <(python3 -I -c '
import re, sys
t, name = sys.argv[1], sys.argv[2]
m = [x for x in re.finditer(r"[A-Za-z]+", t)][-1]
print(len(t) - m.start(), t[m.end():].replace(" ", "%s") or "-")' "$t" "$1")
  "$ADB" shell input keyevent KEYCODE_MOVE_END
  "$ADB" shell input keyevent $(printf 'KEYCODE_DEL %.0s' $(seq 1 "$dels"))
  "$ADB" shell input text "$2${rest#-}"
}
learned() { # word: true when it's in the Dictionary, marked as learned
  "$ADB" shell run-as "$PKG" cat files/personal.json | python3 -I -c '
import json, sys
d = json.load(sys.stdin).get("dictionary", [])
sys.exit(0 if any(e["phrase"] == sys.argv[1] and e.get("autoLearned") for e in d) else 1)' "$1"
}
# 1. Fixed with Quoth's own keys (typed while Quoth is up): learned once the edits settle.
dictate "Please call Nadia"
respell Nadia Nadiah
sleep 6
if learned Nadiah; then echo "PASS auto-learn while Quoth is up"; pass=$((pass+1))
else echo "FAIL auto-learn while Quoth is up"; echo "  field: $(ui text)"; "$ADB" logcat -d -s Quoth | grep -E "auto-learn|inserted|spell" || true; fail=$((fail+1)); fi
# 2. Fixed with another keyboard, then back to Quoth: learned when Quoth sees the field again.
other_ime="$("$ADB" shell ime list -s | tr -d '\r' | grep -v "^$PKG/" | grep -iv voice | head -1)"
if [ -n "$other_ime" ]; then
  dictate "Book a table for Ravi"
  "$ADB" shell ime set "$other_ime" >/dev/null; sleep 2
  respell Ravi Raavi; sleep 1
  "$ADB" shell ime set "$PKG/.android.QuothKeyboardService" >/dev/null; sleep 5
  if learned Raavi; then echo "PASS auto-learn after another keyboard"; pass=$((pass+1))
  else echo "FAIL auto-learn after another keyboard"; echo "  field: $(ui text)"; fail=$((fail+1)); fi
fi
# 3. An ordinary word is never learned ("apples" changed to "apple").
dictate "I bought apples"
respell apples apple; sleep 6
if learned apple; then echo "FAIL ordinary word learned"; fail=$((fail+1))
else echo "PASS ordinary word not learned"; pass=$((pass+1)); fi

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

# A one-line search box: no final period, no line breaks.
"$ADB" shell am start -f 0x10008000 -n "$PKG/.android.MainActivity" --ez search true >/dev/null
sleep 3
ui focus; sleep 2
dictate "weather in Berlin tomorrow"
got="$(ui text)"
if [[ -n "$got" && "$got" != *. && "$got" != *$'\n'* ]]; then echo "PASS search box: no final period ($got)"; pass=$((pass+1))
else echo "FAIL search box"; echo "  got: $got"; fail=$((fail+1)); fi

# Incognito (the app asks keyboards not to remember): the text is inserted, but History doesn't keep it.
history_count() { "$ADB" shell run-as "$PKG" cat files/history.json 2>/dev/null | python3 -I -c '
import json, sys
try: print(len(json.load(sys.stdin)["entries"]))
except Exception: print(0)'; }
n0="$(history_count)"
"$ADB" shell am start -f 0x10008000 -n "$PKG/.android.MainActivity" --ez incognito true >/dev/null
sleep 3
ui focus; sleep 2
dictate "this is a private note"
got="$(ui text)"
if [[ "$got" == *rivate* && "$(history_count)" == "$n0" ]]; then echo "PASS incognito: inserted, not in History"; pass=$((pass+1))
else echo "FAIL incognito"; echo "  got: $got, history $n0 -> $(history_count)"; fail=$((fail+1)); fi

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
