#!/usr/bin/env bash
# Sends requests to dev and prod without stopping until Ctrl-C.
# Every 5s it prints one line per environment: how many requests succeeded or
# failed in that window, and which greetings were served. Ctrl-C prints a total.
#   scripts/load.sh
# Each environment gets two clients running side by side:
#   fast  GET / every 0.2s: catches any failed request, and shows when the greeting changes
#   slow  GET /work?ms=3000 back to back: there is always a request in flight when a
#         pod gets SIGTERM, so a pod that exits before finishing its work shows up here
# Code 000 means no HTTP response at all (refused, reset or timed out).
set -u
tmp=$(mktemp -d)

client() { # env port name path pause
  while true; do
    resp=$(curl -s -m 10 -w '\n%{http_code}' "http://127.0.0.1:$2$4")
    code=${resp##*$'\n'}
    body=$(printf '%s' "${resp%$'\n'*}" | tr -d '\n')
    printf '%s %s %s %s %s\n' "$(date -u +%T)" "$1" "$3" "$code" "$body" >> "$tmp/$1"
    sleep "$5"
  done
}

# One line per env for the requests logged after line $2 of the file.
report() { # env from-line
  tail -n +"$(($2 + 1))" "$tmp/$1" | awk -v env="$1" '
    $4 == "200" { ok++ } $4 != "200" { fail++; bad = bad "\n    FAILED " $0 }
    $3 == "fast" && $4 == "200" { g = $0; sub(/.*Hello /, "", g); sub(/,.*/, "", g); if (!(g in seen)) { seen[g]; names = names (names ? " + " : "") "\"" g "\"" } }
    END { printf "%-5s ok %4d  fail %3d  %s%s\n", env, ok, fail, names, bad }'
}

summary() {
  # shellcheck disable=SC2046  # one PID per word is what kill needs
  kill $(jobs -p) 2>/dev/null
  wait 2>/dev/null
  echo
  echo "== total from $start to $(date -u +%T) UTC"
  report dev 0
  report prod 0
  rm -rf "$tmp"
  exit 0
}
trap summary INT TERM

: > "$tmp/dev"; : > "$tmp/prod"
start=$(date -u +%T)
client dev  30080 fast / 0.2 2>/dev/null &
client dev  30080 slow '/work?ms=3000' 0 2>/dev/null &
client prod 30081 fast / 0.2 2>/dev/null &
client prod 30081 slow '/work?ms=3000' 0 2>/dev/null &
echo "load on dev :30080 and prod :30081 since $start UTC. Ctrl-C to stop."

d=0 p=0
while true; do
  sleep 5
  nd=$(wc -l < "$tmp/dev"); np=$(wc -l < "$tmp/prod")
  echo "$(date -u +%T)  $(report dev "$d")"
  echo "          $(report prod "$p")"
  d=$nd p=$np
done
