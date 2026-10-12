# Evidence

Raw output from running this repository on one machine, kept so the claims in
`DECISIONS.md` can be checked rather than taken on trust.

**Machine:** macOS 26.6 (Intel, x86_64), Docker Engine 20.10.12 with a 6 vCPU / 6 GB VM,
kind v0.33.0, Kubernetes v1.37.0. Times in logs are UTC unless the line says otherwise.

**Conventions**

- Text logs show the command, its output and `[exit N · time]` for every step,
  so each line of output can be traced to the command that produced it.
- Nothing is edited by hand. A step that needed re-running was re-run as a whole.
- Screenshots sit next to the logs they illustrate.
- No credentials, kubeconfigs or Terraform state are stored here.

## Layout

```
evidence/
├── app-provisioning/   building and running the service (tasks 1-4); a reviewer can
│   ├── docker-image/   reproduce all of it with `make up`, so this is supporting detail
│   ├── cluster/
│   ├── helm-chart/
│   └── terraform/
└── drills/             extension D: rolling update and drain under load
```

`ci/`, `alert/` and `gitops/` will sit next to `drills/` as those extensions are
done; the index below lists only what exists.

## Index

In the order the work was done. GitHub sorts folders alphabetically, so use this
table for the reading order.

| Phase | Folder | What it shows | Key result |
|---|---|---|---|
| 1 | [`app-provisioning/docker-image/`](app-provisioning/docker-image/) | The image handles SIGTERM the way the app intends: not-ready first, keeps serving for `SHUTDOWN_DELAY_SECONDS`, then drains in-flight requests | A 15 s request in flight during `docker stop` returned `200`; container exited `0` |
| 2 | [`app-provisioning/cluster/`](app-provisioning/cluster/) | `make cluster` builds 1 control-plane + 3 workers from `kind/cluster.yaml`; the image is loaded into every node | 4 nodes Ready on v1.37.0 in 1m16s; control-plane tainted `NoSchedule`; image (9.57 MB) on all 4 nodes |
| 3 | [`app-provisioning/helm-chart/`](app-provisioning/helm-chart/) | The chart installed on its own into a scratch namespace | 2 replicas on 2 different workers, Ready after the 30 s warm-up |
| 4 | [`app-provisioning/terraform/`](app-provisioning/terraform/) | `make deploy` creates dev and prod from one module | Both releases created in 34 s each; `make deploy` took 1m13s |
| D | [`drills/`](drills/) `rollout-*.png` | Prod greeting changed through `terraform apply` while dev and prod are under continuous load | 0 failed requests; old and new greeting served side by side for about 1 minute; new pods spread 1/1/1 |
| D | [`drills/`](drills/) `drain-result.png` | `kubectl drain greeter-worker2` (1 prod + 1 dev pod) under the same load | 0 failed requests; evicted pods exited 11 s after SIGTERM; drain finished in about 11 s |

## app-provisioning/docker-image/

| File | Content |
|---|---|
| `image-01.png` | `docker run` → `readyz` = `ready`, `version` = `0.1.0` → a 15 s request in flight → `docker stop -t 40` → container log and exit code |

Timeline from the container log in `image-01.png`:

```
09:37:34.415  signal received, shutting down
09:37:34.415  draining: reporting not ready      delay=10s
09:37:44.382  closing listener and draining in-flight requests   timeout_seconds=20
09:37:44.383  shutdown complete
              /work?ms=15000 → code=200, exit=0
```

`docker stop` was given `-t 40` because its default 10 s timeout equals
`SHUTDOWN_DELAY_SECONDS` and would SIGKILL the process before it starts draining.
For the same reason, Kubernetes' `terminationGracePeriodSeconds` has to be longer
than delay + drain (10 + 20 s).

## app-provisioning/cluster/

| File | Content |
|---|---|
| `image-01.png` | `time make cluster`: kind creates the cluster with the pinned `kindest/node:v1.37.0` image and waits until all 4 nodes are Ready (1m16s wall clock) |
| `image-02.png` | `kubectl get nodes -o wide`: 4 nodes Ready, v1.37.0, containerd 2.3.4. The control-plane taint `node-role.kubernetes.io/control-plane:NoSchedule`. kube-proxy in `iptables` mode. `127.0.0.1:30080` listening on the host |
| `image-03.png` | `make image load`: the image is built, then `kind load` copies it into each of the 4 nodes' containerd; `crictl images` on a worker shows `greeter:0.1.0` (9.57 MB) |

Notes:

- The control-plane taint is why the chart's spread constraint uses
  `nodeTaintsPolicy: Honor`: without it the control-plane counts as an empty domain.
- Host ports are bound to `127.0.0.1` only, so the services aren't exposed on the
  machine's network interfaces.

## app-provisioning/helm-chart/

| File | Content |
|---|---|
| `image-01.png` | `helm install` into namespace `chart-test`, then `kubectl get pods -w`: the 2 replicas are scheduled on `greeter-worker` and `greeter-worker2`, start `0/1`, and turn `1/1` about 30 s later when warm-up ends |

## app-provisioning/terraform/

| File | Content |
|---|---|
| `terraform.log` | `terraform fmt`/`validate`, a check that `infra/dev/main.tf` and `infra/prod/main.tf` are identical, then `make deploy`: one `helm_release` created per environment (dev: `Dev`, 2 replicas, port 30080; prod: `Production`, 3 replicas, port 30081) |

## drills/

How the drills were run: three terminals side by side.

- **Left:** `scripts/load.sh` sends requests to dev and prod continuously:
  - `GET /` every 0.2 s;
  - `GET /work?ms=3000` back to back, so a request is always in flight when a pod gets SIGTERM.
  - Every 5 s it prints how many requests succeeded (`ok`) and failed (`fail`: any code other than 200, including no response), and which greetings were served.
- **Middle:** `scripts/watch-pods.sh` shows each pod change with the time. `KILL_AT` appears when the pod gets SIGTERM. Its value is the SIGKILL deadline (SIGTERM + 35 s), and it is moved to the real exit time once the app exits.
- **Right:** the command that causes the disruption.

The load starts before the disruption and runs until after the last old pod has exited.

### Rolling update

| File | Content |
|---|---|
| `rollout-1-during.png` | Start of the rollout: `terraform apply -var 'greeting_name=Production v2'` on the right; the first new pod Ready and the first old pod receiving SIGTERM in the middle; both greetings served on the left |
| `rollout-2-result.png` | End of the rollout: the last old pod exits, `Apply complete!` after 1m34s, and from 13:14:01 only `Production v2` is served. `fail 0` in every 5 s window |
| `rollout-3-spread.png` | The 3 new prod pods on `greeter-worker`, `greeter-worker2` and `greeter-worker3` |

Timeline, from the middle terminal:

```
13:12:23  new pod zglkm (worker)   created, warming up
13:12:54  zglkm Ready      → old pb7x6 gets SIGTERM, not ready at 13:12:57, exits 13:13:05
          new pod fbxv8 (worker2)  created in the same second
13:13:25  fbxv8 Ready      → old 46wwt gets SIGTERM, not ready at 13:13:28, exits 13:13:36
          new pod wzdsk (worker3)  created
13:13:56  wzdsk Ready      → old w5k5x gets SIGTERM, not ready at 13:13:59, exits 13:14:07
```

What it shows:

- **An old pod gets SIGTERM only when its replacement is Ready** (`maxSurge: 1`, `maxUnavailable: 0`). Prod never has fewer than 3 ready pods.
- **The next new pod is created in the same second, without waiting for the old one to exit.** Each step therefore takes the 30 s warm-up rather than warm-up + shutdown, and the whole rollout takes 3 × ~31 s.
- **Every old pod exits about 11 s after SIGTERM.** That is 10 s `SHUTDOWN_DELAY`, then a drain with nothing left in flight, well before the 35 s deadline.
- **Not-ready about 3 s after SIGTERM.** The readiness probe (every 2 s, 2 failures) takes the pod out of the Service within the 10 s delay, so no new request reaches a closed listener.
- **The new pods spread 1/1/1 across the workers** (`matchLabelKeys: [pod-template-hash]`), although before the rollout all 3 prod pods were on `greeter-worker`, left over from an earlier drain test.

### Drain

| File | Content |
|---|---|
| `drain-result.png` | `kubectl drain greeter-worker2 --ignore-daemonsets --delete-emptydir-data` under load: both pods on the node evicted, their replacements created on `greeter-worker`, the old pods exit, `node/greeter-worker2 drained`. `fail 0` in every 5 s window |

Timeline:

```
13:22:38  load starts
13:22:47  drain evicts prod fbxv8 and dev bdp82 (SIGTERM); replacements 5np4v and j6qh7
          created on greeter-worker in the same second
13:22:49  old pods not ready (13:22:49 dev, 13:22:50 prod)
13:22:58  old pods exit, 11 s after SIGTERM; node drained
13:23:13  last window in the screenshot: fail 0
```

What it shows:

- **No requests failed.** The load covered the whole drain.
- **A drain removes first and replaces second.** Unlike the rollout, the replacements only start when the old pods are evicted. Until their 30 s warm-up ends (around 13:23:18), prod runs on 2 ready pods and dev on 1.
- **The PDB had nothing to block here.** `greeter-worker2` held only one pod of each environment, so `maxUnavailable: 1` allowed both evictions at once.
  - An earlier drain of a node holding 2 prod pods showed the other case: the second eviction was refused (`would violate the pod's disruption budget`) and retried every 5 s until the first replacement was Ready.

