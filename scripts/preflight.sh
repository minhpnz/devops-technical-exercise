#!/usr/bin/env bash
# Checks the host before `make up` (default), the drills, or `make lint`.
# Fails loudly instead of letting kind or terraform fail halfway through.
# bash 3.2 safe (stock macOS).
# Usage: scripts/preflight.sh [up|drills|lint|gitops]
set -u
MODE="${1:-up}"

fail=0
ok()   { printf '  ok    %s\n' "$*"; }
warn() { printf '  warn  %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fail=1; }

# ver_ge A B: true if dotted version A >= B
ver_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -n1)" = "$2" ]
}

# need LEVEL name min actual   (LEVEL: bad = required here, warn = needed elsewhere)
need() {
  if [ -z "$4" ]; then "$1" "$2 not found"; return; fi
  if ver_ge "$4" "$3"; then ok "$2 $4"; else "$1" "$2 $4 (need >= $3)"; fi
}
level() { # required-in-modes...
  local m; for m in "$@"; do [ "$m" = "$MODE" ] && { echo bad; return; }; done; echo warn
}

echo "tools ($MODE)"
need "$(level up drills gitops)" docker 20.10 "$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
# Docker >= 23 refuses DOCKER_BUILDKIT=1 without the buildx plugin; Ubuntu's
# docker.io package ships it separately (apt install docker-buildx).
need "$(level up)" "docker buildx" 0.7.0 "$(docker buildx version 2>/dev/null | awk '{print $2}' | tr -d v)"
need "$(level up drills gitops)" kind      0.33.0 "$(kind version 2>/dev/null | awk '{print $2}' | tr -d v)"
# kubectl supports one minor of skew against the 1.37 API server
need "$(level up drills lint gitops)" kubectl   1.36.0 "$(kubectl version --client -o yaml 2>/dev/null | awk '/gitVersion/{print $2; exit}' | tr -d v)"
need "$(level up drills lint gitops)" terraform 1.6.0  "$(terraform version 2>/dev/null | awk 'NR==1{print $2}' | tr -d v)"
# The rest aren't used by `make up` (the Terraform helm provider embeds Helm).
need "$(level lint gitops)" helm 3.10.0 "$(helm version --template '{{.Version}}' 2>/dev/null | tr -d v)"
need "$(level drills gitops)" jq 1.6 "$(jq --version 2>/dev/null | sed 's/^jq-//')"
# the load generator's keep-alive lane uses --rate on a single curl
need "$(level drills gitops)" curl 7.84.0 "$(curl --version 2>/dev/null | awk 'NR==1{print $2}')"
if [ "$MODE" = lint ]; then
  for t in hadolint shellcheck kubeconform; do
    if command -v "$t" >/dev/null; then ok "$t"; else bad "$t not found"; fi
  done
fi

if [ "$MODE" = lint ]; then exit "$fail"; fi

echo "docker"
if docker info >/dev/null 2>&1; then
  cg=$(docker info --format '{{.CgroupVersion}}')
  if [ "$cg" = "2" ]; then ok "cgroup v2"; else bad "cgroup v$cg (only tested on v2)"; fi
  mem=$(docker info --format '{{.MemTotal}}')
  if [ "$mem" -ge 4000000000 ]; then ok "VM memory $((mem / 1048576)) MiB"
  else bad "VM memory $((mem / 1048576)) MiB (want >= 4 GiB for 4 nodes + prometheus)"; fi
  # Informational: `kind load docker-image` has a history of trouble with the
  # containerd image store. `make load LOAD=archive` is the fallback.
  if docker info --format '{{json .DriverStatus}}' | grep -q 'io.containerd.snapshotter'; then
    warn "containerd image store in use; if 'make load' fails, use 'make load LOAD=archive'"
  else
    ok "classic image store (storage driver $(docker info --format '{{.Driver}}'))"
  fi
else
  bad "docker daemon not reachable"
fi

if [ "$MODE" = up ]; then
  echo "ports"
  if kind get clusters 2>/dev/null | grep -qx greeter; then
    ok "cluster 'greeter' exists, skipping port check"
  else
    for p in 30080 30081 30082 30090; do
      # bash's /dev/tcp needs no external tool; a successful connect means taken
      if (: </dev/tcp/127.0.0.1/"$p") 2>/dev/null; then bad "127.0.0.1:$p already in use"
      else ok "port $p free"; fi
    done
  fi
fi

exit "$fail"
