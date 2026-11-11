#!/bin/bash
# Takes the Play Store phone screenshots (1080×2160, Play's 2:1 limit) on a running emulator with sample data:
# a sample Dictionary and History made by dictating `say`-generated speech through the debug-input hook.
# Writes store/screenshots/*.png. Run on the emulator only (it replaces the app's personal data and History).
#   $ANDROID_HOME/emulator/emulator -avd quoth-test -no-window -no-audio &
#   scripts/store-screenshots.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
ADB="$ANDROID_HOME/platform-tools/adb"
PKG=app.quoth
OUT=store/screenshots
WORK="$(mktemp -d)"
trap '"$ADB" shell wm size reset; "$ADB" shell wm density reset; rm -rf "${WORK:?}"' EXIT
mkdir -p "$OUT"
[[ "$("$ADB" get-serialno)" == emulator-* ]] || { echo "Run this on an emulator, not a phone"; exit 1; }

"$ADB" install -r app/build/outputs/apk/debug/app-debug.apk >/dev/null
"$ADB" shell pm grant "$PKG" android.permission.RECORD_AUDIO
"$ADB" shell wm size 1080x2160
"$ADB" shell wm density 420
"$ADB" shell settings put global sysui_demo_allowed 1
"$ADB" shell am broadcast -a com.android.systemui.demo -e command enter >/dev/null
"$ADB" shell am broadcast -a com.android.systemui.demo -e command clock -e hhmm 0930 >/dev/null
"$ADB" shell am broadcast -a com.android.systemui.demo -e command battery -e level 100 -e plugged false >/dev/null
"$ADB" shell am broadcast -a com.android.systemui.demo -e command notifications -e visible false >/dev/null

# Sample Dictionary, written while the app is stopped.
"$ADB" shell am force-stop "$PKG"
cat > "$WORK/personal.json" <<'JSON'
{"dictionary":[
 {"id":"S1","kind":"word","phrase":"Kubernetes","starred":true,"uses":12},
 {"id":"S2","kind":"word","phrase":"Siobhan","uses":5,"autoLearned":true},
 {"id":"S3","kind":"word","phrase":"Quoth","uses":3},
 {"id":"S4","kind":"replacement","phrase":"cube control","replacement":"kubectl","uses":7}],
 "snippets":[{"id":"S5","trigger":"my address","expansion":"12 Rose Lane, Bristol BS1 4XX"}]}
JSON
"$ADB" push -q "$WORK/personal.json" /data/local/tmp/p.json
"$ADB" shell run-as "$PKG" cp /data/local/tmp/p.json files/personal.json
"$ADB" shell run-as "$PKG" rm -f files/history.json files/settings.json
"$ADB" shell rm /data/local/tmp/p.json
"$ADB" shell ime enable "$PKG/.android.QuothKeyboardService" >/dev/null
"$ADB" shell ime set "$PKG/.android.QuothKeyboardService" >/dev/null

cat > "$WORK/ui.py" <<'PY'
import re, subprocess, sys, html
ADB = sys.argv[1]
subprocess.run([ADB, "shell", "rm", "-f", "/sdcard/ui.xml"], capture_output=True)
if "dumped" not in subprocess.run([ADB, "shell", "uiautomator", "dump", "/sdcard/ui.xml"], capture_output=True, text=True).stdout:
    sys.exit("can't read the screen")
x = subprocess.run([ADB, "shell", "cat", "/sdcard/ui.xml"], capture_output=True, text=True).stdout
for t, cls, pkg, d, a, b, c, e in re.findall(r'<node [^>]*?text="([^"]*)"[^>]*?class="([^"]*)"[^>]*?package="([^"]*)"[^>]*?content-desc="([^"]*)"[^>]*?bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', x):
    if pkg != "app.quoth": continue
    if (sys.argv[2] == "field" and cls == "android.widget.EditText") or html.unescape(t) == sys.argv[2] or d == sys.argv[2]:
        subprocess.run([ADB, "shell", "input", "tap", str((int(a)+int(c))//2), str((int(b)+int(e))//2)]); sys.exit(0)
sys.exit("not found: " + sys.argv[2])
PY
tap() { python3 -I "$WORK/ui.py" "$ADB" "$1"; sleep 2; }
shot() { "$ADB" shell screencap -p /sdcard/shot.png; "$ADB" pull -q /sdcard/shot.png "$OUT/$1.png"; echo "$OUT/$1.png"; }
mic_xy() {
  "$ADB" shell dumpsys window InputMethod | python3 -I -c '
import re, sys
s = sys.stdin.read()
m = re.search(r"mFrame=\[(\d+),(\d+)\]\[(\d+),(\d+)\]", s) or re.search(r"frame=\[(\d+),(\d+)\]\[(\d+),(\d+)\]", s)
l, t, r, b = map(int, m.groups()); print((l + r) // 2, b - (b - t) * 45 // 100)'
}
dictate() {
  say -o "$WORK/in.aiff" "$1"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$WORK/in.aiff" "$WORK/in.wav"
  "$ADB" push -q "$WORK/in.wav" /data/local/tmp/in.wav
  "$ADB" shell run-as "$PKG" cp /data/local/tmp/in.wav files/debug-input.wav
  "$ADB" logcat -c
  read -r x y < <(mic_xy)
  "$ADB" shell input tap "$x" "$y"; sleep 1; "$ADB" shell input tap "$x" "$y"
  for _ in $(seq 1 60); do "$ADB" logcat -d -s Quoth | grep -qE "inserted|Didn|failed" && break; sleep 1; done
  sleep 1
}

"$ADB" shell am start -f 0x10008000 -n "$PKG/.android.MainActivity" >/dev/null; sleep 3
shot 1-home
tap field
dictate "Hi Siobhan, um, I'm running about ten minutes late, so save me a seat. See you at the cafe."
dictate "Can you send me the cube control logs from yesterday?"
shot 2-dictating
"$ADB" shell input keyevent BACK; sleep 1
"$ADB" shell input swipe 540 1700 540 600; sleep 1
tap History; shot 3-history; "$ADB" shell input keyevent BACK; sleep 1
tap Dictionary; "$ADB" shell input swipe 540 1700 540 900; sleep 1; shot 4-dictionary; "$ADB" shell input keyevent BACK; sleep 1
tap Style; shot 5-style; "$ADB" shell input keyevent BACK; sleep 1
tap Settings; shot 6-settings

"$ADB" shell run-as "$PKG" rm -f files/debug-input.wav files/personal.json files/history.json
"$ADB" shell am broadcast -a com.android.systemui.demo -e command exit >/dev/null
