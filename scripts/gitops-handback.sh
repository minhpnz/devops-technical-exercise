#!/usr/bin/env bash
# Reverse of gitops-handover.sh: Flux lets go of the dev and prod releases and
# Terraform takes them back, under load, without uninstalling anything.
#
#   1. Suspend the root Kustomization, so Flux stops re-creating HelmReleases.
#   2. Per environment: suspend the HelmRelease, then delete it. helm-controller
#      skips the uninstall for a suspended HelmRelease, so the Helm release
#      (and the pods) stay. Checked, not assumed: abort if the release is gone.
#   3. terraform import the release into infra/<env>, then apply. The env
#      tfvars match gitops/apps (scripts/check-env-deltas.sh), so the apply is a
#      Helm upgrade with no pod changes.
#
# Flux, the git server and the suspended Kustomization stay installed;
# `make gitops` resumes them.
# Usage: scripts/gitops-handback.sh [OUTDIR]
set -u
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="${1:-$ROOT/evidence/gitops-handback}"
mkdir -p "$OUT" && OUT=$(cd "$OUT" && pwd)
: > "$OUT/timeline.txt"
log() { echo "$(now) $*" | tee -a "$OUT/timeline.txt"; }

"$ROOT/scripts/check-env-deltas.sh" > "$OUT/env-deltas.txt" 2>&1 \
  || { cat "$OUT/env-deltas.txt"; echo "tfvars and gitops/apps disagree; refusing to hand back"; exit 1; }
for e in dev prod; do
  k -n "greeter-$e" get pods -o name > "$OUT/$e-pods-before.txt"
done

load_start=$(now)
"$ROOT/scripts/load.sh" "$OUT/load" 2>>"$OUT/timeline.txt" &
LOADPID=$!
abort() { log "FAILED: $*"; kill -TERM "$LOADPID"; stop_jobs; exit 1; }
sleep 5

k -n flux-system patch kustomization apps --type merge -p '{"spec":{"suspend":true}}' >/dev/null \
  || abort "suspend Kustomization"
log "Kustomization apps suspended"

for e in dev prod; do
  ns="greeter-$e"
  k -n "$ns" patch helmrelease greeter --type merge -p '{"spec":{"suspend":true}}' >/dev/null || abort "suspend $e"
  k -n "$ns" delete helmrelease greeter --wait=true --timeout=60s >/dev/null || abort "delete HelmRelease $e"
  helm --kube-context "$CONTEXT" -n "$ns" status greeter >/dev/null 2>&1 || abort "Helm release $e is gone"
  log "$e: HelmRelease deleted while suspended; Helm release still deployed"
  (cd "$ROOT/infra/$e" && terraform init -input=false >/dev/null && \
    terraform import -no-color -input=false module.greeter.helm_release.greeter "$ns/greeter") \
    >> "$OUT/terraform.txt" 2>&1 || abort "terraform import $e"
  log "$e: imported into Terraform state"
  (cd "$ROOT/infra/$e" && terraform plan -no-color -input=false) > "$OUT/$e-plan.txt" 2>&1
  log "$e: plan: $(grep -E '~ update in-place|must be replaced|No changes|Plan:' "$OUT/$e-plan.txt" | tr -s ' ' | tr '\n' ' ')"
  (cd "$ROOT/infra/$e" && terraform apply -no-color -input=false -auto-approve) > "$OUT/$e-apply.txt" 2>&1 \
    || abort "terraform apply $e"
  log "$e: terraform apply done"
done
for e in dev prod; do
  (cd "$ROOT/infra/$e" && terraform plan -no-color -input=false -detailed-exitcode >/dev/null 2>&1)
  log "$e: second plan exit=$? (0 = no changes)"
done
sleep 10
kill -TERM "$LOADPID"; wait "$LOADPID" 2>/dev/null
log "load stopped"

{
  echo "== timeline"; sed 's/^/  /' "$OUT/timeline.txt" | grep -v '^  load '
  echo; echo "== Flux objects left"
  k get kustomization -n flux-system 2>&1 | sed 's/^/  /'
  k get helmrelease -A 2>&1 | sed 's/^/  /'
  for e in dev prod; do
    echo; echo "== $e"
    helm --kube-context "$CONTEXT" -n "greeter-$e" history greeter --max 3 2>&1 | sed 's/^/  /'
    echo "  pods replaced by the hand-back: $(k -n "greeter-$e" get pods -o name | grep -v -x -c -F -f "$OUT/$e-pods-before.txt")"
  done
  echo; echo "== probe failures since load start"
  for e in dev prod; do unhealthy_since "greeter-$e" "$load_start" | sed "s/^/  $e /"; done
  echo; echo "== load"; "$ROOT/scripts/load-report.sh" "$OUT/load"
} > "$OUT/summary.txt" 2>&1
cat "$OUT/summary.txt"
