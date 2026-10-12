#!/usr/bin/env bash
# Makes GreeterProdHighErrorRatio fire and resolve, logging every state change
# from Prometheus' API. Takes ~12 minutes: `for: 5m` is not shortened for the
# demo, and resolving waits for the bad requests to age out of the 5m window.
#
#   phase 1  prod: 4 req/s to /boom + 1 req/s to /   (80% errors)
#            dev:  the same, to show dev never pages
#   phase 2  once firing has held for 60s: stop /boom, keep 1 req/s to /
#
# Usage: scripts/drill-alert.sh [OUTFILE]
set -u
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="${1:-$ROOT/evidence/alert-firing.log}"
PROM=http://127.0.0.1:30090

rate_curl() { # rate url
  curl -s -o /dev/null --rate "$1" --max-time 100000 "$2?n=[1-1000000]" 2>/dev/null
}
alert_state() { # prints inactive|pending|firing for the given namespace's alert
  curl -s "$PROM/api/v1/alerts" | jq -r '[.data.alerts[] | select(.labels.alertname=="GreeterProdHighErrorRatio") | .state] | first // "inactive"'
}
ratio() { # env -> 5m error ratio excluding probes, as the rule computes it
  local q="sum(rate(greeter_http_requests_total{namespace=\"greeter-$1\",status=~\"5..\",path!~\"/healthz|/readyz\"}[5m])) / sum(rate(greeter_http_requests_total{namespace=\"greeter-$1\",path!~\"/healthz|/readyz\"}[5m]))"
  curl -s --data-urlencode "query=$q" "$PROM/api/v1/query" | jq -r '.data.result[0].value[1] // "none"' | cut -c1-5
}
ratios() { echo "error ratio prod=$(ratio prod) dev=$(ratio dev)"; }

: > "$OUT"
log() { echo "$(now) $*" | tee -a "$OUT"; }

curl -fsS "$PROM/-/ready" >/dev/null || { echo "prometheus not reachable on :30090"; exit 1; }
log "rule: $(curl -s "$PROM/api/v1/rules" | jq -r '.data.groups[].rules[] | select(.name=="GreeterProdHighErrorRatio") | "for=\(.duration)s state=\(.state)"')"

rate_curl 1/s http://127.0.0.1:30081/ &
GOOD=$!
rate_curl 4/s http://127.0.0.1:30081/boom &
BAD_PROD=$!
rate_curl 4/s http://127.0.0.1:30080/boom &
BAD_DEV=$!
log "phase 1: prod 4/s /boom + 1/s /, dev 4/s /boom"

last=""; fired_at=""; phase=1
while :; do
  st=$(alert_state)
  if [ "$st" != "$last" ]; then log "STATE $st ($(ratios))"; last=$st; fi
  if [ "$st" = firing ] && [ -z "$fired_at" ]; then fired_at=$(date +%s); fi
  if [ "$phase" = 1 ] && [ -n "$fired_at" ] && [ $(( $(date +%s) - fired_at )) -ge 60 ]; then
    killtree "$BAD_PROD"; killtree "$BAD_DEV"
    phase=2; log "phase 2: /boom stopped, 1/s / continues ($(ratios))"
  fi
  if [ "$phase" = 2 ] && [ "$st" = inactive ]; then break; fi
  n=$((${n:-0} + 1)); [ $((n % 4)) -eq 0 ] && log "  still $st ($(ratios))"
  sleep 15
done
killtree "$GOOD"; wait 2>/dev/null
log "resolved ($(ratios))"
