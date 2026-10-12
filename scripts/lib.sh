# shellcheck shell=bash
# Shared helpers for the drill scripts. Sourced, not executed. bash 3.2 safe.
CONTEXT="${CONTEXT:-kind-greeter}"
# Terraform's helm provider doesn't read $KUBECONFIG; point it at the first entry.
if [ -n "${KUBECONFIG:-}" ]; then export TF_VAR_kubeconfig="${KUBECONFIG%%:*}"; fi
k() { kubectl --context "$CONTEXT" "$@"; }

# Prefix every line on stdin with a UTC timestamp to the millisecond. macOS
# date has no %N, so this goes through perl, which both macOS and Linux have.
stamp() {
  perl -MPOSIX=strftime -MTime::HiRes=time -ne \
    '$|=1; my $t=time; printf "%s.%03dZ %s", strftime("%Y-%m-%dT%H:%M:%S", gmtime $t), ($t-int $t)*1000, $_'
}

now() { perl -MPOSIX=strftime -MTime::HiRes=time -e \
  'my $t=time; printf "%s.%03dZ\n", strftime("%Y-%m-%dT%H:%M:%S", gmtime $t), ($t-int $t)*1000'; }

# Watch EndpointSlice conditions for a service: one line per change. Goes
# through jq because kubectl's jsonpath `range` only renders the first object
# of a watch stream.
watch_endpoints() { # namespace service
  k -n "$1" get endpointslice -l "kubernetes.io/service-name=$2" -w -o json \
    | jq -r --unbuffered '[.endpoints[]? | "\(.targetRef.name | split("-") | last) ready=\(.conditions.ready) serving=\(.conditions.serving) term=\(.conditions.terminating)"] | join("  ")' \
    | stamp
}

# Watch pods: phase, ready, node, and the container exit code once terminated.
watch_pods() { # namespace
  k -n "$1" get pods -w --output-watch-events -o \
    jsonpath='{.type} {.object.metadata.name} node={.object.spec.nodeName} phase={.object.status.phase} ready={.object.status.containerStatuses[0].ready} deleting={.object.metadata.deletionTimestamp} exit={.object.status.containerStatuses[0].state.terminated.exitCode}{"\n"}' \
    | stamp
}

# Kill a background job and everything under it (the kubectl at the far end of
# a pipeline isn't the job's pid).
killtree() {
  local c
  for c in $(pgrep -P "$1"); do killtree "$c"; done
  kill "$1" 2>/dev/null
}

stop_jobs() {
  local p
  for p in $(jobs -p); do killtree "$p"; done
  wait 2>/dev/null
}

# Unhealthy (probe failure) events in a namespace since an ISO timestamp, one
# line per event series: last-seen, pod, count, message.
unhealthy_since() { # namespace iso-ts
  k -n "$1" get events --field-selector reason=Unhealthy -o json \
    | jq -r --arg t "${2%.*}Z" '.items[] | select((.lastTimestamp // .eventTime) >= $t)
        | "\(.lastTimestamp) \(.involvedObject.name) x\(.count) \(.message)"' | sort
}

# Port-forward the in-cluster git server to 127.0.0.1:$GIT_PORT for a push.
# The server isn't exposed on a host port on purpose: pushing is an operator
# action, Flux reads it in-cluster.
GIT_PORT="${GIT_PORT:-18090}"
# shellcheck disable=SC2034  # used by the scripts that source this
GIT_URL="http://127.0.0.1:$GIT_PORT/greeter.git"
git_forward_start() {
  k -n gitops rollout status deploy/git-server --timeout=120s >/dev/null || return 1
  k -n gitops port-forward svc/git-server "$GIT_PORT:80" >/dev/null 2>&1 &
  GIT_FWD_PID=$!
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    (: </dev/tcp/127.0.0.1/"$GIT_PORT") 2>/dev/null && return 0
    sleep 1
  done
  echo "port-forward to git-server did not come up" >&2; return 1
}
git_forward_stop() { [ -n "${GIT_FWD_PID:-}" ] && killtree "$GIT_FWD_PID"; }

# Ask Flux to fetch now instead of waiting for the next interval tick.
flux_poke() {
  local ts; ts=$(date -u +%s)
  k -n flux-system annotate --overwrite gitrepository/greeter "reconcile.fluxcd.io/requestedAt=$ts" >/dev/null
  k -n flux-system annotate --overwrite kustomization/apps "reconcile.fluxcd.io/requestedAt=$ts" >/dev/null
}
