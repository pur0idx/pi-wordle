#!/usr/bin/env bash
# Hammer the app and print, per request, its status and the pods/nodes that
# served it. Leave this running while a Pi is pulled: you see failures while
# Kubernetes reacts, then 200s again once replacements are up.
#
#   scripts/demo.sh [base-url]        default http://localhost:8080
set -uo pipefail
BASE="${1:-http://localhost:8080}"

# Python kept in a quoted heredoc so it needs no shell escaping and runs on
# the python3 that ships with macOS (3.9) as well as on Ubuntu.
read -r -d '' SUMMARIZE <<'PY'
import json, sys
label, code = sys.argv[1], sys.argv[2]
try:
    body = json.load(sys.stdin)
except Exception:
    body = {}
hops = " -> ".join("%s@%s" % (t.get("service"), t.get("node")) for t in body.get("trace", []))
if "error" in body:
    extra = body["error"]
elif "pattern" in body:
    extra = body["pattern"]
elif "remaining" in body:
    extra = "%d left" % body["remaining"]
else:
    extra = body.get("puzzle_id", "")
mark = "\033[32mOK \033[0m" if code.startswith("2") else "\033[31mERR\033[0m"
print("%s %3s %-14s %-22s %s" % (mark, code, label, str(extra)[:22], hops))
PY

summarize() { python3 -c "$SUMMARIZE" "$1" "$2"; }

hit() {
  local label=$1; shift
  local out code
  out=$(curl -s --max-time 5 -w $'\n%{http_code}' "$@" 2>/dev/null)
  code=${out##*$'\n'}
  printf '%s' "${out%$'\n'*}" | summarize "$label" "${code:-000}"
}

WORDS=(slate crane pilot brick grand house)
i=0
while true; do
  PID=$(curl -s --max-time 5 "$BASE/api/today" | python3 -c 'import json,sys; print(json.load(sys.stdin)["puzzle_id"])' 2>/dev/null)
  PID=${PID:-$(date +%F)}
  printf '\033[90m%s\033[0m ' "$(date +%T)"; hit "today" "$BASE/api/today"
  w=${WORDS[$((i % ${#WORDS[@]}))]}
  printf '\033[90m%s\033[0m ' "$(date +%T)"; hit "guess $w" -X POST "$BASE/api/guess" \
    -H 'content-type: application/json' -d "{\"puzzle_id\":\"$PID\",\"guess\":\"$w\"}"
  printf '\033[90m%s\033[0m ' "$(date +%T)"; hit "hint" -X POST "$BASE/api/hint" \
    -H 'content-type: application/json' -d "{\"history\":[{\"guess\":\"$w\",\"pattern\":\"BBBBB\"}]}"
  i=$((i + 1))
  sleep 1
done
