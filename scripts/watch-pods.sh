#!/usr/bin/env bash
# Prints every change to the greeter pods (dev and prod), with the UTC time in front.
#   scripts/watch-pods.sh        Ctrl-C to stop.
# Columns are shortened so three terminals fit side by side in one screenshot:
#   POD      <replicaset hash>-<suffix>; a new hash means a pod of the new rollout
#   READY    false while the pod warms up or drains
#   KILL_AT  appears when the pod gets SIGTERM (the time at the start of that line)
#            and shows when SIGKILL would follow: SIGTERM + terminationGracePeriodSeconds.
#            It is moved to the actual exit time once the app exits by itself.
echo 'TIME     ENV  POD              NODE    READY KILL_AT'
kubectl --context kind-greeter get pods -A -l app.kubernetes.io/name=greeter -w --no-headers \
  -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,NODE:.spec.nodeName,READY:.status.containerStatuses[0].ready,DEL:.metadata.deletionTimestamp' |
  while read -r ns pod node ready del; do
    [ "$del" = "<none>" ] && del="" || del=${del:11:8}
    printf '%s %-4s %-16s %-7s %-5s %s\n' "$(date -u +%T)" "${ns#greeter-}" "${pod#greeter-}" "${node#greeter-}" "$ready" "$del"
  done
