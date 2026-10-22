#!/bin/bash
# In-app end-to-end checks: drives the installed Quoth.app with synthetic speech (macOS `say`)
# through the debug hook, into a throwaway text window, and checks what lands in the field.
# Your personal.json is backed up and restored.
set -uo pipefail
cd "$(dirname "$0")/../.."
SUP="$HOME/Library/Application Support/Quoth"
TMP="$(mktemp -d)"
PASS=0; FAIL=0

restart() {
  pkill -x Quoth; sleep 1; open "$HOME/Applications/Quoth.app"
  for i in $(seq 1 60); do curl -s -o /dev/null http://127.0.0.1:8178/ && break; sleep 1; done
  # With the built-in language model, also wait until llama-server has loaded it.
  sleep 2; if pgrep -x llama-server >/dev/null; then
    for i in $(seq 1 120); do [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8179/health)" = 200 ] && break; sleep 1; done
  fi
  sleep 6
}
speak() { say ${3:+-v $3} -o "$TMP/$1.wav" --data-format=LEI16@16000 "$2"; }
check() { # name, wav, initial, expected, [extra args]
  local got; got=$(swift scripts/dev/e2e-target.swift "$TMP/$2.wav" "$3" "${@:5}" 2>/dev/null | python3 -c 'import sys,re; t=sys.stdin.read(); m=re.search(r"FIELD<<(.*)>>", t, re.S); print(m.group(1) if m else "")')
  if GOT="$got" EXP="$4" python3 -c 'import os,sys; sys.exit(0 if os.environ["GOT"] in os.environ["EXP"].split("|") else 1)'; then PASS=$((PASS+1)); echo "✓ $1"; else FAIL=$((FAIL+1)); echo "✗ $1"; echo "    expected: $(printf %q "$4")"; echo "    got:      $(printf %q "$got")"; fi
}

defaults write app.quoth debugHooks -bool true
pkill -x Quoth; sleep 1
[ -f "$SUP/personal.json" ] && cp -f "$SUP/personal.json" "$TMP/personal.backup"
cat > "$SUP/personal.json" <<'JSON'
{"dictionary":[{"id":"11111111-1111-1111-1111-111111111111","kind":"replacement","phrase":"cube control","replacement":"kubectl","starred":false,"uses":0,"autoLearned":false,"createdAt":0}],
 "snippets":[{"id":"22222222-2222-2222-2222-222222222222","trigger":"my calendar link","expansion":"https://cal.com/alex"}],
 "autoLearn":true}
JSON
restart

speak list "um so my goals for this week are number one finish the report number two call the bank"
speak cont "and then we ship it on friday"
speak dict "please install cube control today, here is my calendar link"
speak back "hey sam, I was thinking we could push the launch to friday, no wait, to monday. does that work for you?"
speak snip "my calendar link"
speak name "please send the contract to Zorvathian"

echo "CLIP-SENTINEL" | pbcopy
check "list with lead-in"        list ""                         $'My goals for this week are:\n1. Finish the report\n2. Call the bank|So my goals for this week are:\n1. Finish the report\n2. Call the bank'
check "continuation"             cont "First we finish testing"  "First we finish testing and then we ship it on Friday."
check "dictionary + snippet"     dict ""                         "Please install kubectl today. Here is https://cal.com/alex.|Please install kubectl today, here is https://cal.com/alex."
check "backtrack"                back ""                         "Hey Sam, I was thinking we could push the launch to Monday. Does that work for you?"
check "snippet alone"            snip ""                         "https://cal.com/alex"
sleep 1; [ "$(pbpaste)" = "CLIP-SENTINEL" ] && { PASS=$((PASS+1)); echo "✓ clipboard restored"; } || { FAIL=$((FAIL+1)); echo "✗ clipboard: $(pbpaste)"; }

# Auto-learn: correct the misheard name, then dictate again.
first=$(swift scripts/dev/e2e-target.swift "$TMP/name.wav" 2>/dev/null | sed -n 's/.*contract to \(.*\)\.>>.*/\1/p')
swift scripts/dev/e2e-target.swift "$TMP/name.wav" --edit "$first=Zorvathian" --wait 7 >/dev/null 2>&1
grep -q '"Zorvathian"' "$SUP/personal.json" && { PASS=$((PASS+1)); echo "✓ auto-learned Zorvathian (heard: $first)"; } || { FAIL=$((FAIL+1)); echo "✗ auto-learn (heard: $first)"; }
check "learned word used"        name ""                         "Please send the contract to Zorvathian."

# Phase 3: Command Mode and Transforms (LLM output varies, so check shape not exact text)
speak cmd1 "make this more formal"
speak cmd2 "translate this to German"
like() { # name, regex, args...
  local name="$1" re="$2"; shift 2
  local got; got=$(swift scripts/dev/e2e-target.swift "$@" 2>/dev/null | python3 -c 'import sys,re; t=sys.stdin.read(); m=re.search(r"FIELD<<(.*)>>", t, re.S); print(m.group(1) if m else "")')
  if GOT="$got" RE="$re" python3 -c 'import os,re,sys; sys.exit(0 if re.search(os.environ["RE"], os.environ["GOT"], re.S) else 1)'; then
    PASS=$((PASS+1)); echo "✓ $name"; else FAIL=$((FAIL+1)); echo "✗ $name"; echo "    got: $(printf %q "$got")"; fi
}
like "command: edit selection"   '^(?!.*\b(u|thx)\b).*(please|could|would).*file' "$TMP/cmd1.wav" "hey can u send me the file asap thx" --select-all --hook command --wait 14
like "command: whole field"      '(?i)danke'                                 "$TMP/cmd2.wav" "Thank you for your help today." --hook command --wait 14
like "transform: polish"         '^.{20,200}$'                               1 "I wanted to let you know that, as I mentioned before, the launch which we had planned is going to be delayed, and the reason it is delayed is because the vendor was late with the parts." --select-all --hook transform --wait 14
like "transform: unset is no-op" '^abc$'                                     5 "abc" --select-all --hook transform --wait 3

pkill -x Quoth; sleep 1
if [ -f "$TMP/personal.backup" ]; then cp -f "$TMP/personal.backup" "$SUP/personal.json"; else rm -f "$SUP/personal.json"; fi
open "$HOME/Applications/Quoth.app"
rm -rf "$TMP"
echo; echo "$PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
