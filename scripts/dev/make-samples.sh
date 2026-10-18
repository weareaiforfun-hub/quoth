#!/bin/bash
# Regenerates Evals/samples (synthetic speech with known text) for the Model Lab's speech comparison.
# Synthetic voices are cleaner than real speech, so real recordings from History are the better test.
set -euo pipefail
cd "$(dirname "$0")/../.."
D=Evals/samples
mkdir -p "$D"
gen() { say -v "$2" -o "$D/$1.wav" --data-format=LEI16@16000 "$3"; }
gen names   Samantha "Please forward the Kubernetes migration plan to Priya Raghunathan and copy Jonas Eklund."
gen jargon  Daniel   "Our new hire, Siobhan O'Callaghan, starts on the GraphQL gateway and the Postgres migration next week."
gen casual  Karen    "Um, so I think we should, uh, push the release to Thursday, actually no, Friday works better."
cat > "$D/samples.json" <<'JSON'
[
  {"file": "names.wav", "text": "Please forward the Kubernetes migration plan to Priya Raghunathan and copy Jonas Eklund."},
  {"file": "jargon.wav", "text": "Our new hire, Siobhan O'Callaghan, starts on the GraphQL gateway and the Postgres migration next week."},
  {"file": "casual.wav", "text": "Um, so I think we should, uh, push the release to Thursday, actually no, Friday works better."}
]
JSON
echo "Wrote $(/bin/ls "$D"/*.wav | wc -l | tr -d ' ') samples to $D"
