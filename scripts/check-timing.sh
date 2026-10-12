#!/usr/bin/env bash
# Zero-downtime rollouts and drains rest on two inequalities between numbers
# that live in different places. Neither helm lint nor kubeconform can see them,
# so a "harmless" tweak (a shorter SHUTDOWN_DELAY, a slower readiness probe)
# would pass every other check and start dropping requests.
#   scripts/check-timing.sh [extra helm args, e.g. --set timing.shutdownDelaySeconds=3]
#
# 1. readiness detection + endpoint propagation < SHUTDOWN_DELAY
#    The pod must be out of the Service before it closes its listener.
# 2. SHUTDOWN_DELAY + DRAIN_TIMEOUT < terminationGracePeriodSeconds
#    The app must finish draining before the kubelet sends SIGKILL.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# Margin for the EndpointSlice update to reach kube-proxy on every node.
PROPAGATION=2

read -r grace delay drain period threshold < <(
  helm template greeter "$ROOT/charts/greeter" --set greetingName=lint "$@" \
    --show-only templates/deployment.yaml |
  awk '
    /terminationGracePeriodSeconds:/ { grace = $2 }
    /- name: SHUTDOWN_DELAY_SECONDS/ { want = "delay" }
    /- name: DRAIN_TIMEOUT_SECONDS/  { want = "drain" }
    /value:/ && want != "" { gsub(/"/, "", $2); v[want] = $2; want = "" }
    /readinessProbe:/ { probe = 1 }
    /livenessProbe:/  { probe = 0 }
    probe && /periodSeconds:/    { period = $2 }
    probe && /failureThreshold:/ { threshold = $2 }
    END { print grace, v["delay"], v["drain"], period, threshold }')

if [ -z "$threshold" ]; then
  echo "FAIL could not read the timing values from the rendered Deployment"; exit 1
fi

fail=0
detect=$((period * threshold))
if [ $((detect + PROPAGATION)) -le "$delay" ]; then
  echo "ok   readiness ${period}s x ${threshold} = ${detect}s, +${PROPAGATION}s propagation <= SHUTDOWN_DELAY ${delay}s"
else
  echo "FAIL readiness ${period}s x ${threshold} = ${detect}s, +${PROPAGATION}s propagation > SHUTDOWN_DELAY ${delay}s:"
  echo "     the pod closes its listener while the Service still sends it requests"; fail=1
fi
if [ $((delay + drain)) -lt "$grace" ]; then
  echo "ok   SHUTDOWN_DELAY ${delay}s + DRAIN_TIMEOUT ${drain}s < terminationGracePeriodSeconds ${grace}s"
else
  echo "FAIL SHUTDOWN_DELAY ${delay}s + DRAIN_TIMEOUT ${drain}s >= terminationGracePeriodSeconds ${grace}s:"
  echo "     the kubelet SIGKILLs the pod before it finishes draining"; fail=1
fi
exit "$fail"
