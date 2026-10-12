#!/usr/bin/env bash
# The per-environment values exist twice: infra/<env>/terraform.tfvars (used
# until `make gitops`) and gitops/apps/<env>/values.yaml (used after). After
# the handover the GitOps file is authoritative; this keeps the two from
# drifting apart so a hand-back doesn't silently change an environment.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
fail=0
tf()  { awk -F'=' -v k="$2" '$1 ~ "^"k" *$" {v=$2; gsub(/^ *"?|"? *$/, "", v); print v}' "$ROOT/infra/$1/terraform.tfvars"; }
gy()  { awk -v k="$2" '$1 == k":" {sub(/^[^:]*: */, ""); gsub(/"/, ""); print}' "$ROOT/gitops/apps/$1/values.yaml"; }
for e in dev prod; do
  for pair in greeting_name:greetingName replicas:replicas image_tag:tag node_port:nodePort; do
    a=$(tf "$e" "${pair%%:*}"); b=$(gy "$e" "${pair##*:}")
    if [ "$a" = "$b" ]; then echo "ok   $e ${pair%%:*}=$a"
    else echo "FAIL $e ${pair%%:*}: tfvars '$a' vs gitops '$b'"; fail=1; fi
  done
done
exit "$fail"
