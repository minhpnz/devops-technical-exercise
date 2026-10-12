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
  - The drills (extension D) back this up on kind: no request failed. Behind a cloud
    load balancer with its own health checks, deregistration can take longer, and I'd
    re-measure before trusting 10 s.
- **Keep-alive clients are untested.** The drill's load opens a new connection per
  request. A client holding one connection open stays pinned to the old pod (conntrack)
  until that pod closes the listener, so it relies on the app closing idle connections
  cleanly. I'd add a keep-alive client to the drill before calling this proven.
- **The alert counts errors rather than measuring a ratio** (see extension B).
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
- **Delivery:** Terraform for the platform (cluster, network, IAM, a one-off Flux
  bootstrap); Flux for every application from the start, with no Terraform-owned
  releases to hand over (see extension C).
- **Traffic:** a real load balancer or Ingress, with the shutdown delay tuned against its
  deregistration time.
- **Capacity:** an HPA, and resource sizes taken from load tests rather than guesses.
- **Network:** NetworkPolicy (default deny), and spreading across zones as well as hosts.

## Deliberately left out

- **HPA, NetworkPolicy, Ingress, ServiceAccount, ConfigMap.** Each would be a file I
  couldn't justify for this service on a local cluster.
- **Secrets in the repository.** There are none. The app's only configuration is a
  greeting name, and the one credential in the setup (Flux's deploy key, extension C)
  lives only in a Secret in the cluster.
- **The drills in CI.** See extension A.

## Extensions: order and status

Done in this order: **D → A → B → C**.

1. **D – prove it survives.** The core tasks claim zero-downtime drains and rollouts, and
   this is the only extension that tests that claim. If it had failed, the chart was
   wrong and everything after it would be built on that.
2. **A – CI.** Once D showed the config works, CI keeps it working: every push re-checks
   what a reviewer would otherwise have to trust.
3. **B – observability.** An alert is only worth having once the system it watches is
   known to behave (D) and stays that way (A).
4. **C – GitOps.** Mostly plumbing, and it conflicts with task 4: Terraform owns the
   releases, so adopting Flux means handing ownership over safely.

### D – prove it survives

Evidence: [`evidence/drills/`](evidence/drills/) (screenshots, explained in
[`evidence/README.md`](evidence/README.md)).

- **Method:** three terminals side by side: continuous load (`scripts/load.sh`), pod
  changes with timestamps (`scripts/watch-pods.sh`), and the command causing the
  disruption. The load starts before the disruption and stops after the last old pod
  has exited.
  - The load includes a 3 s request in a loop, so a request is always in flight when a
    pod gets SIGTERM.
- **Rolling update** (prod greeting changed through `terraform apply`): 0 failed
  requests. An old pod got SIGTERM only once its replacement was Ready. Each old pod
  exited about 11 s after SIGTERM, well inside the 35 s grace period.
- **Drain** of a worker: 0 failed requests. The difference from a rollout: a drain
  removes first and replaces second.
  - Prod ran on 2 pods during the replacement's 30 s warm-up.
  - When the node held two prod pods, the PDB refused the second eviction until the
    first replacement was Ready.
- **What I learned the hard way:** draining a second node while the first was still
  cordoned put every replica on the one remaining worker.
  - No request failed, so nothing flagged it, but the service no longer survived a node
    loss.
  - Pods also don't move back after `uncordon`.
  - Check `kubectl get nodes` for `SchedulingDisabled` before draining.

### A – CI

`.github/workflows/ci.yml`, three jobs:

- **`static`:** actionlint, shellcheck, hadolint, `make lint`, `make rules-test`, and two
  checks of my own:
  - **lock files:** they cover all 4 platforms, so `terraform init` works on a Mac with
    Apple silicon and on the Linux runner alike;
  - **`scripts/check-images.sh`:** every image `make up` pulls is digest-pinned and has
    an arm64 build.
- **`image`:** the Dockerfile's test stage (`go vet`, `go test -race`), the build, an
  arm64 cross-build, and a Trivy scan.
- **`e2e`:** `make up` on a fresh runner: cluster, image, both environments, smoke test.
- **Actions are pinned to commit SHAs**, and Dependabot proposes updates for actions,
  base images and Terraform providers.
- **The drills are not in CI, on purpose.** A rollout under load on a 2-vCPU runner adds
  about 8 minutes per push and fails falsely when the runner starves itself.
  - Instead, `scripts/check-timing.sh` (in `make lint`) checks the two numbers
    zero-downtime depends on. It takes under a second.
  - The first check: readiness detection plus 2 s propagation must fit inside
    `SHUTDOWN_DELAY`.
  - The second check: delay plus drain must fit inside the grace period.
  - Shortening `SHUTDOWN_DELAY` to 3 s now fails lint, where before it would have passed
    every check and dropped requests.
  - For a service that changes often I'd still run the drill nightly.

### B – observability

Prometheus server only (no Alertmanager or exporters), in its own Terraform root
(`infra/monitoring`), scraping every 15 s. One rule, `GreeterProdErrors`:

```
sum(rate(greeter_http_requests_total{namespace="greeter-prod", status=~"5..", path!~"/healthz|/readyz"}[1m])) > 1
for: 30s
```

- **Probe paths are excluded.** `/readyz` returns 503 by design during every warm-up and
  drain, so without the filter every rollout would page someone.
- **Prod only.** Dev failing at the same rate never pages, and the demo shows both side
  by side.
- **`promtool` unit tests** (`make rules-test`, also in CI) cover four cases:
  - prod errors fire;
  - dev errors don't;
  - errors under the threshold don't;
  - `/readyz` 503s during a rollout don't.
  - Removing the probe filter makes the last test fail, so the test really guards it.
- **What I'd change for production:**
  - **A ratio rather than a count.** More than 1 error per second is nothing at
    1000 req/s and a lot at 2 req/s. I'd use errors / total with a minimum-traffic
    floor, or better a multi-window burn-rate alert against an SLO.
  - **`for: 30s` is short so the alert can be demonstrated in about a minute.** In
    production I'd use 5 minutes or more: an alert that fires for incidents that fix
    themselves teaches people to ignore the pager.
  - **The blind spot:** if every pod is down there are no metrics, and this rule stays
    silent. A second alert on `greeter_ready`, plus a blackbox probe from outside, would
    cover it.

### C – GitOps

Flux (source, kustomize and helm controllers only; images pinned by digest) reconciles
`gitops/apps/{dev,prod}.yaml` from the `solution` branch on GitHub. A commit that changes
a HelmRelease's values rolls the cluster within a minute, with no deploy command run.

- **Who owns what.**
  - Flux owns the two app releases: the HelmReleases reuse the release name and
    namespace Terraform created, so Flux upgrades them in place and no pod is replaced.
  - Terraform keeps `infra/monitoring`.
- **Hand-over order: Flux takes over first, Terraform lets go second.**
  `terraform state rm` runs only after both HelmReleases report Ready.
  - Done the other way round, a Flux failure (wrong key, unpushed commit) would leave
    the releases with no owner.
  - `make deploy-*` refuses to run once a HelmRelease exists, so Terraform can't
    overwrite what Flux owns.
- **Authentication: a deploy key, set up as for a private repository** (it works the
  same if the repository is public).
  - The key is generated for Flux alone, never my personal SSH key or a token.
  - It is read-only and scoped to this one repository.
  - It lives only in the `greeter-repo` Secret in the cluster; the private key file is
    deleted after the Secret is created, and it never enters git.
  - GitHub's host keys come from `api.github.com/meta` over HTTPS, rather than trusting
    whatever `ssh-keyscan` sees first.
  - The cost: to run the GitOps part themselves, a reviewer forks the repository,
    creates their own deploy key and changes the `url` in
    `gitops/flux-system/sync.yaml`.
  - In production I'd use a GitHub App (short-lived, rotated tokens), with secrets
    managed by SOPS or External Secrets instead of created by hand.
- **Bootstrapped by hand.** `helm install` for Flux and `kubectl apply` for
  `sync.yaml`, because this only runs on my machine.
- **Why a hand-over at all.** Task 4 asks for Terraform to deploy the releases, so
  Terraform creates them first and Flux takes them over afterwards. That is what makes
  the `state rm` ordering necessary.
- **What I'd do in production instead: Terraform bootstraps Flux and never owns the
  apps.** This follows the approach the Flux maintainers recommend
  ([Flux blog, April 2026](https://fluxcd.io/blog/2026/04/terraform-flux-operator-bootstrap/)):
  - Terraform runs one bootstrap Job, via the Flux Operator module, in the same root
    that creates the cluster. The Job installs Flux only if it is missing, then Flux
    adopts itself and every application from Git.
  - Terraform never holds those objects in its state. So there is no `state rm`
    hand-over to get wrong, no guard needed on `make deploy`, and `terraform plan` stays
    clean afterwards.
  - The Git credential goes in as a sensitive input of which only a hash is stored, so
    the key never lands in `terraform.tfstate`.
  - That matters: creating the same Secret with the `kubernetes_secret` resource would
    put the private key in the state in plain text.
  - The trade-off is that `terraform plan` no longer shows what changes in the cluster;
    the review moves to the Git diff. For platform components that change rarely, I'd
    accept that.
  - I didn't use it here because it would replace task 4 rather than build on it, and it
    adds Flux Operator, `FluxInstance` and a new module for two releases on a local
    cluster.
- **Left out:**
  - a way to hand the releases back to Terraform (suspend the HelmRelease, delete it,
    `terraform import`);
  - image automation, since there is no registry.

Evidence: [`evidence/gitops/`](evidence/gitops/), to be added once the demo is recorded.
