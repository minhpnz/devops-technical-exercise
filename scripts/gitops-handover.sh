#!/usr/bin/env bash
# Moves ownership of the dev and prod releases from Terraform to Flux, under
# load, without uninstalling or re-installing anything:
#
#   1. Terraform installs Flux, the git server and the GitRepository/Kustomization
#      (and resumes the Kustomization if a previous hand-back suspended it).
#   2. This repo's HEAD is pushed to the in-cluster git server.
#   3. Flux's HelmReleases (same release name/namespace) upgrade the existing
#      Helm releases in place. Terraform still has them in state, but nothing
#      applies the env roots meanwhile.
#   4. Only once both HelmReleases are Ready does Terraform forget the releases
#      (state rm). If anything before that fails, Terraform still owns them.
#
# After this, `make deploy-dev`/`deploy-prod` refuse to run: two owners for one
# release is how you get changes silently reverted.
# Usage: scripts/gitops-handover.sh [OUTDIR]
set -u
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="${1:-$ROOT/evidence/gitops-handover}"
mkdir -p "$OUT" && OUT=$(cd "$OUT" && pwd)
: > "$OUT/timeline.txt"
log() { echo "$(now) $*" | tee -a "$OUT/timeline.txt"; }

for e in dev prod; do
  helm --kube-context "$CONTEXT" -n "greeter-$e" history greeter --max 3 > "$OUT/$e-helm-history-before.txt" 2>&1
  k -n "greeter-$e" get pods -o name > "$OUT/$e-pods-before.txt"
done

load_start=$(now)
"$ROOT/scripts/load.sh" "$OUT/load" 2>>"$OUT/timeline.txt" &
LOADPID=$!
sleep 5

(cd "$ROOT/infra/gitops" && terraform init -input=false >/dev/null && \
  terraform apply -no-color -input=false -auto-approve) > "$OUT/terraform-gitops-apply.txt" 2>&1 \
  || { log "terraform apply infra/gitops failed"; tail -n 20 "$OUT/terraform-gitops-apply.txt"; kill -TERM "$LOADPID"; exit 1; }
log "terraform: flux + git server + bootstrap applied"
if [ "$(k -n flux-system get kustomization apps -o jsonpath='{.spec.suspend}')" = true ]; then
  k -n flux-system patch kustomization apps --type merge -p '{"spec":{"suspend":false}}' >/dev/null
  log "resumed Kustomization apps (suspended by an earlier hand-back)"
fi

abort() { log "FAILED: $*"; kill -TERM "$LOADPID"; stop_jobs; exit 1; }
"$ROOT/scripts/gitops-push.sh" >> "$OUT/timeline.txt" 2>&1 || abort "git push to the in-cluster server"
log "pushed $(git -C "$ROOT" rev-parse --short HEAD); waiting for Flux"
k -n flux-system wait --for=condition=Ready gitrepository/greeter --timeout=180s >/dev/null || abort "GitRepository not Ready"
log "GitRepository Ready: $(k -n flux-system get gitrepository greeter -o jsonpath='{.status.artifact.revision}')"
k -n flux-system wait --for=condition=Ready kustomization/apps --timeout=300s >/dev/null || abort "Kustomization not Ready"
for e in dev prod; do
  # after a hand-back the HelmRelease is recreated by the resumed Kustomization
  n=0; until k -n "greeter-$e" get helmrelease greeter >/dev/null 2>&1; do
    n=$((n + 1)); [ "$n" -gt 120 ] && abort "HelmRelease $e never appeared"; sleep 1
  done
  k -n "greeter-$e" wait --for=condition=Ready helmrelease/greeter --timeout=300s >/dev/null || abort "HelmRelease $e not Ready"
  k -n "greeter-$e" rollout status deploy/greeter --timeout=180s >/dev/null || abort "rollout $e"
done
log "Flux reports both HelmReleases Ready"
for e in dev prod; do
  if (cd "$ROOT/infra/$e" && terraform state list 2>/dev/null | grep -q '^module.greeter.helm_release.greeter$'); then
    (cd "$ROOT/infra/$e" && terraform state rm -no-color module.greeter.helm_release.greeter) >> "$OUT/terraform.txt" 2>&1
    log "terraform ($e): release removed from state, not destroyed"
  else
    log "terraform ($e): release not in state (already handed over)"
  fi
done

sleep 10
kill -TERM "$LOADPID"; wait "$LOADPID" 2>/dev/null
log "load stopped"

{
  echo "== timeline"; sed 's/^/  /' "$OUT/timeline.txt" | grep -v '^  load '
  echo; echo "== Flux objects"
  k get gitrepository,kustomization -n flux-system 2>&1 | sed 's/^/  /'
  k get helmrelease -A 2>&1 | sed 's/^/  /'
  for e in dev prod; do
    echo; echo "== $e: helm history (before -> after)"
    sed 's/^/  /' "$OUT/$e-helm-history-before.txt"
    echo "  --"
    helm --kube-context "$CONTEXT" -n "greeter-$e" history greeter --max 3 2>&1 | sed 's/^/  /'
    echo "  pods replaced by the handover: $(k -n "greeter-$e" get pods -o name | grep -v -x -c -F -f "$OUT/$e-pods-before.txt")"
  done
  echo; echo "== probe failures since load start"
  for e in dev prod; do unhealthy_since "greeter-$e" "$load_start" | sed "s/^/  $e /"; done
  echo; echo "== load"; "$ROOT/scripts/load-report.sh" "$OUT/load"
} > "$OUT/summary.txt" 2>&1
cat "$OUT/summary.txt"
