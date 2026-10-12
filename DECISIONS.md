# Decisions

The commits show what I built. This file explains why, where I'm unsure, and what I
would change for a real production service. The evidence for each claim is in
[`evidence/`](evidence/README.md).

## How to run it

```sh
make up      # cluster → image → load → deploy dev + prod → smoke test
make down
```

Dev is served on http://127.0.0.1:30080/ and prod on http://127.0.0.1:30081/.

## What drove the design

Most choices come from two behaviours of the app, so I tested them before writing any
config:

- **Startup:** `/healthz` returns 200 immediately, but `/readyz` returns 503 for the
  first 30 s.
- **Shutdown:** on SIGTERM the app reports not-ready, keeps serving for 10 s, drains for
  up to 20 s, and exits 2 if the drain runs over.

I checked shutdown in Docker before writing any Kubernetes config. A 15 s request was
in flight when I ran `docker stop -t 40`. It returned 200 and the container exited 0.
Docker's default 10 s stop timeout would have killed the process before it even started
draining (`evidence/app-provisioning/docker-image/`). Kubernetes has the same trap, which
is why the grace period below is calculated rather than left at the default.

## Per task

### 1. Image

- **Two stages.** The build stage uses `golang:bookworm`. The runtime stage uses
  `distroless/static:nonroot`.
  - The runtime image has only the static binary: no shell and no package manager.
    `docker run --entrypoint sh` fails, which is intended.
  - I chose bookworm over alpine for the builder because the test stage runs
    `go test -race`, which needs cgo and gcc. The official Go images are built and
    tested on Debian; the Alpine variant is not officially supported.
- **Tests in the build.** `go vet` and `go test -race` run in a `test` target, so
  `docker build --target test` is the same gate locally and in CI. The default target
  doesn't depend on it, so building the runtime image doesn't run the tests twice.
- **Pinned base images.** Both base images are pinned by digest, with the tag kept for
  readability. A tag can be re-pushed, and "a cluster you care about" should get the
  same bytes every time.
  - **Cost:** the digests don't receive security patches by themselves. In production,
    Dependabot or Renovate would open PRs to bump them.
- **`USER 65532:65532`, numeric, user and group.**
  - It must be numeric so the kubelet can check `runAsNonRoot` without reading
    `/etc/passwd`.
  - A bare UID leaves the process with GID 0, which is root's group.
- **Exec-form `ENTRYPOINT ["/greeter"]`.** The binary runs as PID 1 and receives SIGTERM
  directly. In shell form, `sh -c` sits in front of it, and on Debian that shell (dash)
  doesn't pass the signal on. The container then waits until it is SIGKILLed and never
  drains.
- **`--platform=$BUILDPLATFORM` with `TARGETOS`/`TARGETARCH`.** The build cross-compiles
  instead of emulating, so an arm64 image builds quickly on an amd64 runner.
  - These only work as a set. Setting `--platform` without passing `GOARCH` produces an
    image labelled arm64 that contains an amd64 binary.

### 2. Cluster

- **kind**, with 1 control-plane node and 3 workers, defined in `kind/cluster.yaml`.
  - The brief asks for at least two workers. With exactly two, draining one leaves a
    single schedulable node, so every replica ends up on it and "survives node loss"
    stops being true at the moment it matters.
- **Node image pinned by digest**, so the reviewer's cluster is the same Kubernetes
  build as mine (v1.37.0).
- **Host ports are mapped at create time and bound to `127.0.0.1`:** 30080 (dev), 30081
  (prod), 30082 (spare) and 30090 (Prometheus).
  - kind can't add port mappings to an existing cluster. The spare port means adding a
    third environment doesn't require recreating the cluster.
- **Images are side-loaded** with `kind load` and run with `imagePullPolicy:
  IfNotPresent`, so no registry is needed.
- **Result:** the cluster comes up in 1m16s and the image is present on all 4 nodes
  (`evidence/app-provisioning/cluster/`).

### 3. Helm chart (hand-written: Deployment, Service, PDB)

**Probes**
- Readiness checks `/readyz` every 2 s and marks the pod not-ready after 2 failures, so
  about 4 s after SIGTERM. That is well inside the app's 10 s shutdown delay, which
  leaves the endpoint controller and kube-proxy time to remove the pod from routing.
- Liveness checks `/healthz` with a looser setting. It passes during warm-up, so I didn't
  add a startupProbe: liveness never fails during warm-up, so a startupProbe would have
  nothing to protect.

**`terminationGracePeriodSeconds` = delay + drain + 5 s buffer**
- It is computed in the template from the same values that are passed to the app as
  environment variables. Changing one timing value cannot leave the grace period too
  short.

**Rolling update: `maxSurge: 1`, `maxUnavailable: 0`**
- Old pods are removed only after the new pod has passed readiness, which takes 30 s of
  warm-up.
- That makes rollouts slow, but capacity never drops below the replica count.

**Topology spread: `maxSkew: 1` per hostname, `DoNotSchedule`**
- `nodeTaintsPolicy: Honor` stops the tainted control-plane and cordoned nodes from
  counting as empty domains. Without it the scheduler can believe the spread is
  unsatisfiable.
- `matchLabelKeys: [pod-template-hash]` makes the spread apply within each ReplicaSet.
  New pods are spread among themselves rather than counted against the old pods that
  are about to go.
- The chart-test install showed 2 replicas placed on 2 different workers and becoming
  Ready after about 30 s (`evidence/app-provisioning/helm-chart/`).

**PDB: `maxUnavailable: 1`, not `minAvailable`**
- It means "one pod down at a time" whatever the replica count. `minAvailable: 1` on
  prod's 3 replicas would allow a drain to take two pods at once.
- `unhealthyPodEvictionPolicy: AlwaysAllow` stops a pod that is already broken from
  blocking a drain.

**Greeting name is required, enforced twice**
- `required` in the template, plus a `values.schema.json` that also requires
  `replicas >= 2`.
- The app exits if the name is empty, so I would rather the render fail than ship a pod
  that crash-loops.

**Hardening**
- Non-root, read-only root filesystem, all capabilities dropped, `RuntimeDefault`
  seccomp, and no service-account token (the app never calls the API).

**Resources**
- The memory request equals the memory limit. There is no CPU limit, because CFS
  throttling would show up as latency spikes and buy nothing for this workload.

### 4. Terraform

- **One module (`infra/modules/greeter`) plus one directory per environment.** Each
  environment directory has the same `main.tf`; only `terraform.tfvars` differs
  (greeting, replicas, node port). The namespace comes from the directory name.
- **I rejected workspaces.** Separate directories mean separate state, and the
  environment is visible in the path. With workspaces it is a hidden piece of CLI state,
  and running `apply` in the wrong workspace is easy.
- **The Helm provider has a blind spot, and the `chartHash` value works around it.**
  - The provider only detects changes to the chart version or to the values. Editing a
    template in a local chart plans as "No changes".
  - I pass a hash of the chart's files as an extra value. Any edit to the chart then
    shows up as a values diff.
- **`wait` + `atomic` + `cleanup_on_fail`.** `apply` returns only once the pods are
  Ready. A failed rollout is rolled back instead of being left half-done.
- **Variable validation catches mistakes at plan time:**
  - a blank greeting;
  - fewer than 2 replicas;
  - a node port that kind doesn't map to the host. That one would otherwise deploy
    successfully and be unreachable.
- **Result:** `make deploy` takes about 1m13s for both environments
  (`evidence/app-provisioning/terraform/`). Changing the prod greeting plans as an
  in-place update of one release (`1 to change, 0 to destroy`). The only line that
  changes in `values` is `greetingName`.

## Least sure about

- **Readiness timing vs. routing.**
  - The 10 s shutdown delay assumes kube-proxy removes the pod's endpoint within about
    6 s of it turning not-ready.
  - On a busy cluster, or behind a cloud load balancer with its own health checks, that
    may not hold.
  - The rolling-update drill (extension D) is how I'd find out. If requests fail there,
    I'd add a `preStop` sleep or lengthen the delay.
- **Dev has 2 replicas with `maxUnavailable: 1`.** During a drain dev drops to half
  capacity. That's acceptable for dev, but it's the reason replicas can't go below 2.
- **`DoNotSchedule`.**
  - If two of the three workers are lost, the scheduler won't stack the evicted pods on
    the remaining worker. They stay Pending.
  - Pending is honest, but `ScheduleAnyway` would keep more pods running. I chose strict
    spreading because the brief is about surviving one node, not two.
- **The `main.tf` file is duplicated in each environment.** It is short, and I kept it
  explicit. With a third environment I would generate it or use Terragrunt.

## Considered and rejected

| Option | Why not |
|---|---|
| Kustomize | Values per environment are easier to pass from Terraform into Helm, and the timing values must be computed inside the template. |
| Ingress or Gateway | Needs an ingress controller only to reach one service. A NodePort plus kind's port mapping is enough to reach it from outside the cluster. |
| `kubernetes` Terraform provider with raw manifests | Duplicates the chart, and loses Helm's release history and rollback. |
| Local registry | Adds a moving part. `kind load` does the same job here. |
| startupProbe | Liveness already passes during warm-up, so there is nothing for it to protect. |

## Ambiguities and the assumption I made

- **"Reachable from outside the cluster"** → from the host machine, on `127.0.0.1`. It is
  not exposed on the network.
- **"Loss of a single node"** → a worker node. In kind the control-plane is a single
  point of failure in any case.
- **Dev and prod** run as separate namespaces in one cluster. That is enough to show the
  two environments differ; in reality they would be separate clusters.

## For something genuinely production-facing

- **Images:** pushed to a registry, signed, scanned in CI, and deployed by digest rather
  than tag. Base-image digest bumps automated with Dependabot or Renovate.
- **Terraform:** remote state with locking. Separate clusters and credentials per
  environment, with prod applied only from CI after the plan has been reviewed.
- **Traffic:** a real load balancer or Ingress, with the shutdown delay tuned against its
  deregistration time.
- **Capacity:** an HPA, and resource sizes taken from load tests rather than guesses.
- **Network:** NetworkPolicy (default deny), and spreading across zones as well as hosts.

## Deliberately left out

- **HPA, NetworkPolicy, Ingress, ServiceAccount, ConfigMap.** Each would be a file I
  couldn't justify for this service on a local cluster.
- **Secrets.** There are none. The only configuration is a greeting name.
- **The `/metrics` scrape config.** It belongs to extension B rather than the core chart.

## Extensions: order and status

I chose this order:

1. **D – prove it survives.** The core tasks claim zero-downtime drains and rollouts, and
   this is the only extension that tests that claim.
2. **B – observability.** An alert I'd want to be woken up for is the next thing a real
   on-call needs.
3. **A – CI.** The Dockerfile's test target already does most of what a pipeline would
   run.
4. **C – GitOps.** It is the most plumbing for the least new evidence about the service
   itself.

**Status:** not started yet. When an extension is done, its evidence will go in
`evidence/drills/`, `evidence/alert/`, `evidence/ci/` or `evidence/gitops/`.
