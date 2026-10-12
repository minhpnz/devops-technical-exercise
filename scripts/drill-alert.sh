#!/usr/bin/env bash
# Makes GreeterProdErrors fire, for a demo.
#   scripts/drill-alert.sh        Ctrl-C to stop the load.
# Sends 5 req/s to /boom on prod and on dev, plus 1 req/s to / on prod. Dev
# must never page. Every 15s it prints the alert state and the errors per
# second the rule sees. Expect pending after ~30s and firing about 30s after that.
set -u
PROM=http://127.0.0.1:30090
curl -fsS "$PROM/-/ready" >/dev/null || { echo "prometheus not reachable on :30090"; exit 1; }

hit() { # rate url; exec so that killing the job kills curl itself
  exec curl -s -o /dev/null --rate "$1" "$2?n=[1-1000000]"
}
state() {
  curl -s "$PROM/api/v1/alerts" |
    jq -r '[.data.alerts[] | select(.labels.alertname=="GreeterProdErrors") | .state] | first // "inactive"'
}
errors() { # env -> 5xx per second over 1m, probes excluded, as the rule computes it
  curl -s --data-urlencode "query=sum(rate(greeter_http_requests_total{namespace=\"greeter-$1\",status=~\"5..\",path!~\"/healthz|/readyz\"}[1m]))" \
    "$PROM/api/v1/query" | jq -r '.data.result[0].value[1] // "0" | tonumber * 10 | floor / 10'
}

hit 1/s http://127.0.0.1:30081/ &
hit 5/s http://127.0.0.1:30081/boom &
hit 5/s http://127.0.0.1:30080/boom &
# shellcheck disable=SC2046  # one PID per word is what kill needs
trap 'kill $(jobs -p) 2>/dev/null; echo "load stopped"; exit 0' INT TERM

start=$(date +%s)
echo "load: prod 5/s /boom + 1/s /, dev 5/s /boom. Ctrl-C to stop."
while true; do
  printf '%s  +%3ds  alert %-8s  errors/s prod %-4s dev %s\n' \
    "$(date -u +%T)" $(($(date +%s) - start)) "$(state)" "$(errors prod)" "$(errors dev)"
  sleep 15
done
