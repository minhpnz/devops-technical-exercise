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
│   └── cluster/
├── drills/             extension D: drain and rolling update under load
├── ci/                 extension A
├── alert/              extension B: the alert firing
└── gitops/             extension C
```

`drills/`, `ci/`, `alert/` and `gitops/` are added as each extension is done; the
index below lists only what exists.

## Index

In the order the work was done. GitHub sorts folders alphabetically, so use this
table for the reading order.

| Phase | Folder | What it shows | Key result |
|---|---|---|---|
| 1 | [`app-provisioning/docker-image/`](app-provisioning/docker-image/) | The image handles SIGTERM the way the app intends: not-ready first, keeps serving for `SHUTDOWN_DELAY_SECONDS`, then drains in-flight requests | A 15 s request in flight during `docker stop` returned `200`; container exited `0` |
| 2 | [`app-provisioning/cluster/`](app-provisioning/cluster/) | `make cluster` builds 1 control-plane + 3 workers from `kind/cluster.yaml`; the image is loaded into every node | 4 nodes Ready on v1.37.0 in 1m16s; control-plane tainted `NoSchedule`; image (9.57 MB) on all 4 nodes |

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
