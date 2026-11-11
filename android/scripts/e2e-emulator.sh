#!/bin/bash
# End-to-end check of the Quoth keyboard on a running emulator, or a phone with USB debugging (unlocked, screen on):
# installs the debug APK, enables the keyboard, then dictates `say`-generated speech into the
# setup screen's "Try it here" box through the debug-input hook, and checks the text that lands. Then the same
# through Earshot (the floating bubble) with another keyboard, in Quoth and in Contacts.
# The device's keyboard, accessibility services, settings.json, personal.json and history.json are put back at the end.
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

# Every tap and keystroke goes to whatever is in front, so stop unless it's Quoth, or the app a case expects
# (a crash would otherwise leave the test typing into the launcher or another app).
front() { # [package, default Quoth]
  local want="${1:-$PKG}"
  "$ADB" shell dumpsys window | grep -m1 "mCurrentFocus" | grep -q "$want/" ||
    { echo "STOP: $want isn't in front ($("$ADB" shell dumpsys window | grep -m1 mCurrentFocus | tr -s ' '))"; exit 1; }
}

# The mic button lives in the keyboard window, which uiautomator doesn't dump: find it from the keyboard's bounds.
mic_xy() {
  "$ADB" shell dumpsys window InputMethod | python3 -I -c '
import re, sys
s = sys.stdin.read()
m = re.search(r"mFrame=\[(\d+),(\d+)\]\[(\d+),(\d+)\]", s) or re.search(r"frame=\[(\d+),(\d+)\]\[(\d+),(\d+)\]", s)
l, t, r, b = map(int, m.groups())
print((l + r) // 2, b - (b - t) * 45 // 100)'
}

speech() { # text-to-speak: becomes the debug input
  say -o "$WORK/in.aiff" "$1"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$WORK/in.aiff" "$WORK/in.wav"
  "$ADB" push -q "$WORK/in.wav" /data/local/tmp/in.wav
  "$ADB" shell run-as "$PKG" cp /data/local/tmp/in.wav files/debug-input.wav
}
wait_insert() {
  for _ in $(seq 1 60); do
    "$ADB" logcat -d -s Quoth | grep -qE "inserted|Didn|failed|nothing" && break
    "$ADB" logcat -d -s Quoth | grep -q "timing" && sleep 1 && break
    sleep 1
  done
  "$ADB" logcat -d -s Quoth | grep -oE "timing.*" || true
}

dictate() { # text-to-speak, with the Quoth keyboard
  speech "$1"
  "$ADB" logcat -c
  front
  read -r x y < <(mic_xy)
  "$ADB" shell input tap "$x" "$y"; sleep 1; "$ADB" shell input tap "$x" "$y"
  wait_insert
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
had_personal=false; had_history=false; had_settings=false
ime_before="$("$ADB" shell settings get secure default_input_method | tr -d '\r')"
a11y_before="$("$ADB" shell settings get secure enabled_accessibility_services | tr -d '\r')"; [ "$a11y_before" = null ] && a11y_before=""
a11y_on_before="$("$ADB" shell settings get secure accessibility_enabled | tr -d '\r')"
if "$ADB" shell run-as "$PKG" ls files/settings.json >/dev/null 2>&1; then
  had_settings=true
  "$ADB" shell run-as "$PKG" cp files/settings.json files/settings.json.e2e-backup
fi
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
  "$ADB" shell run-as "$PKG" rm -f files/personal.json files/history.json files/settings.json
  if $had_settings; then "$ADB" shell run-as "$PKG" mv files/settings.json.e2e-backup files/settings.json; fi
  if [ -n "$a11y_before" ]; then "$ADB" shell settings put secure enabled_accessibility_services "$a11y_before"
  else "$ADB" shell settings delete secure enabled_accessibility_services >/dev/null; fi
  [ "$a11y_on_before" = null ] || "$ADB" shell settings put secure accessibility_enabled "$a11y_on_before"
  [ -z "$ime_before" ] || [ "$ime_before" = null ] || "$ADB" shell ime set "$ime_before" >/dev/null || true
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
  front
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
front
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
front
read -r x y < <(mic_xy)
"$ADB" shell input tap "$x" "$y"; sleep 1; "$ADB" shell input tap "$x" "$y"; sleep 5
if "$ADB" logcat -d -s Quoth | grep -q timing; then echo "FAIL password box (it transcribed)"; fail=$((fail+1)); else check "password box inserts nothing" ""; fi

# ---- Earshot: the floating bubble, with another keyboard ----
# Enables the accessibility service and Earshot's setting (the user's own are put back at the end), switches to
# another keyboard (Gboard on the emulator), and dictates by tapping the bubble.
earshot_window() { # prints the bubble's centre, or nothing when it isn't on screen
  "$ADB" shell dumpsys window windows | python3 -I -c '
import re, sys
s = sys.stdin.read()
i = s.find(" Earshot}:")
if i < 0: sys.exit()
m = re.search(r" frame=\[(\d+),(\d+)\]\[(\d+),(\d+)\]", s[i:i + 4000])
if m:
    l, t, r, b = map(int, m.groups())
    # The pill grows from the side it sits on; its microphone end is the outer 60 dp or so.
    print(r - (b - t) // 2 if l > 0 else l + (b - t) // 2, (t + b) // 2)'
}
wait_bubble() { for _ in $(seq 1 10); do [ -n "$(earshot_window)" ] && return 0; sleep 1; done; return 1; }
dictate_bubble() { # text-to-speak, app expected in front
  speech "$1"
  "$ADB" logcat -c
  wait_bubble || { echo "  (no bubble on screen)"; return 1; }
  front "$2"
  read -r x y < <(earshot_window)
  "$ADB" shell input tap "$x" "$y"; sleep 1
  front "$2"
  read -r x y < <(earshot_window)
  "$ADB" shell input tap "$x" "$y"
  wait_insert
}
other_ime="$("$ADB" shell ime list -s | tr -d '\r' | grep -v "^$PKG/" | grep -iv voice | head -1)"
if [ -z "$other_ime" ]; then
  echo "SKIP Earshot: no other keyboard on this device"
else
  "$ADB" shell am force-stop "$PKG"
  "$ADB" shell run-as "$PKG" cat files/settings.json 2>/dev/null > "$WORK/settings.json" || true
  python3 -I -c '
import json, sys
p = sys.argv[1]
try: d = json.load(open(p))
except Exception: d = {}
d.update(earshot=True, earshotSnoozedUntil=0, earshotHiddenApps=[])
json.dump(d, open(p, "w"))' "$WORK/settings.json"
  "$ADB" push -q "$WORK/settings.json" /data/local/tmp/settings.json
  "$ADB" shell run-as "$PKG" cp /data/local/tmp/settings.json files/settings.json
  "$ADB" shell rm /data/local/tmp/settings.json
  service="$PKG/app.quoth.android.EarshotService"
  # Written afresh (without it, then with it), because force-stopping the app also unbinds the service.
  others="$(printf '%s' "$a11y_before" | tr ':' '\n' | grep -v "^$service$" | paste -sd: - || true)"
  "$ADB" shell settings put secure enabled_accessibility_services "${others:-none}"; sleep 1
  "$ADB" shell settings put secure enabled_accessibility_services "${others:+$others:}$service"
  "$ADB" shell settings put secure accessibility_enabled 1
  "$ADB" shell ime set "$other_ime" >/dev/null
  echo "Earshot with $other_ime"

  # 1. Quoth's own try-it box, with the other keyboard.
  "$ADB" shell am start -f 0x10008000 -n "$PKG/.android.MainActivity" >/dev/null
  sleep 3
  front; ui focus; sleep 2
  if dictate_bubble "Hi Sam, see you at three" "$PKG"; then
    check "Earshot in Quoth's box" "Hi Sam, see you at 3." "Hi Sam, see you at 3:00."
    before="$(ui text)"
    dictate_bubble "Could you bring the slides for Thursday" "$PKG"
    got="$(ui text)"
    # Appended once, after a space, starting a new sentence.
    if [[ "$got" == "$before C"*slides* && "$got" != *slides*slides* ]]; then echo "PASS Earshot appends at the cursor"; pass=$((pass+1))
    else echo "FAIL Earshot appends at the cursor"; echo "  got: $got"; fail=$((fail+1)); fi
  else echo "FAIL Earshot in Quoth's box: no bubble"; fail=$((fail+1)); fi

  # 2. Another app: a new contact's name box in Contacts (never saved: force-stopped afterwards).
  contacts="$("$ADB" shell pm list packages | tr -d '\r' | grep -oE "com\.(google\.)?android\.contacts$" | head -1)"
  if [ -n "$contacts" ]; then
    "$ADB" shell am force-stop "$contacts"
    "$ADB" shell am start -a android.intent.action.INSERT -t vnd.android.cursor.dir/contact -p "$contacts" >/dev/null
    sleep 4
    front "$contacts"; ui focus; sleep 2
    if dictate_bubble "Blue Harbor Bakery" "$contacts"; then
      got="$(ui text)"
      # Exactly once (a "set text" that lands late must not be pasted again).
      if [[ "$got" =~ ^Blue\ Harbo(u)?r\ Bakery\.?$ ]]; then echo "PASS Earshot in Contacts ($got)"; pass=$((pass+1))
      else echo "FAIL Earshot in Contacts"; echo "  got: $got"; fail=$((fail+1)); fi
    else echo "FAIL Earshot in Contacts: no bubble"; fail=$((fail+1)); fi
    "$ADB" shell am force-stop "$contacts"
  else
    echo "SKIP Earshot in another app: no Contacts app"
  fi

  # 3. A password box: no bubble.
  "$ADB" shell am start -f 0x10008000 -n "$PKG/.android.MainActivity" --ez password true >/dev/null
  sleep 3
  front; ui focus
  if wait_bubble; then echo "FAIL Earshot in a password box (the bubble showed)"; fail=$((fail+1))
  else echo "PASS Earshot stays out of password boxes"; pass=$((pass+1)); fi

  # 4. The Quoth keyboard is up: no bubble (it has its own microphone).
  "$ADB" shell ime set "$PKG/.android.QuothKeyboardService" >/dev/null
  "$ADB" shell am start -f 0x10008000 -n "$PKG/.android.MainActivity" >/dev/null
  sleep 3
  front; ui focus
  if wait_bubble; then echo "FAIL Earshot hides for the Quoth keyboard"; fail=$((fail+1))
  else echo "PASS Earshot hides while the Quoth keyboard is up"; pass=$((pass+1)); fi
fi

"$ADB" shell run-as "$PKG" rm -f files/debug-input.wav
"$ADB" shell rm -f /data/local/tmp/in.wav
echo "e2e: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
