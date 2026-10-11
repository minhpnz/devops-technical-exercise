# what3words — DevOps Technical Exercise

Thanks for taking the time to do this. This document is everything you need.

## The short version

You are given a small HTTP service. Your job is to make it run properly on Kubernetes — built,
packaged, deployed through infrastructure as code, and operable — **entirely on your own machine**.

- **Budget about 4 hours.** We mean that as a real number, not a polite one. See *If you run out of
  time* below, which is written to be used.
- **No cloud account, no credentials, no spend.** Everything runs locally. Nothing in this exercise
  requires AWS or any paid service, and we don't want you spending money on it.
- **You will not write any application code.** The service is in Go, but the exercise is not a Go test.
  You never need to modify it, and knowing Go is not required.
- **Work in this repository.** Push to a branch named `solution` and open a pull request against
  `main` when you're done.

We'd rather see four things done well and a clear account of your reasoning than eight things rushed.

---

## What you've been given

The service lives in `app/`. It behaves like a real production service, which is the point — several of
its characteristics exist specifically to make the deployment work non-trivial.

### Endpoints

| Endpoint | Behaviour |
|---|---|
| `GET /` | Returns a greeting using the configured name |
| `GET /healthz` | **Liveness.** Returns `200` for as long as the process is alive, including while it is still starting up |
| `GET /readyz` | **Readiness.** Returns `503` while warming up, `200` once ready, and `503` again as soon as shutdown begins |
| `GET /version` | Returns the configured version string |
| `GET /metrics` | Prometheus text format: request counters, a latency histogram, build info, and a readiness gauge |
| `GET /boom` | Always returns `500`. Provided so you can demonstrate an alert firing |
| `GET /work?ms=N` | Sleeps for N milliseconds (max 30000) before responding. Provided so you can observe in-flight requests during a rollout or drain |

### Configuration

All configuration is by environment variable.

| Variable | Default | Notes |
|---|---|---|
| `GREETING_NAME` | **none — required** | The service **exits with a non-zero status** if this is unset or empty |
| `PORT` | `8080` | |
| `VERSION` | `dev` | Reported on `/version` and as a label on `greeter_build_info` |
| `WARMUP_SECONDS` | `30` | How long the service reports not-ready after starting |
| `SHUTDOWN_DELAY_SECONDS` | `10` | On `SIGTERM`, how long it keeps serving *after* it starts reporting not-ready |
| `DRAIN_TIMEOUT_SECONDS` | `20` | How long it then waits for in-flight requests to finish |

### Startup and shutdown, precisely

Worth reading twice — these two behaviours drive most of the exercise.

**Startup.** The process starts listening immediately, but reports `503` on `/readyz` for
`WARMUP_SECONDS` (30 by default). Liveness passes throughout. This models a service that has to warm a
cache or establish connections before it can serve traffic.

**Shutdown.** On `SIGTERM` the service:

1. immediately starts returning `503` on `/readyz`, while continuing to serve normal traffic;
2. waits `SHUTDOWN_DELAY_SECONDS` — this is the window in which the cluster is expected to notice it is
   unready and stop routing new requests to it;
3. stops accepting new connections and waits up to `DRAIN_TIMEOUT_SECONDS` for in-flight requests to
   complete;
4. exits `0`.

This is deliberate, correct behaviour. Your configuration needs to accommodate it.

### Running and testing it directly

```sh
cd app
go test ./...
GREETING_NAME=YourName WARMUP_SECONDS=5 go run .
```

*Environment note, so you don't lose time to it:* on recent macOS versions a natively-built Go binary
that uses cgo may fail to start with a `missing LC_UUID load command` error from `dyld`. Setting
`CGO_ENABLED=0` avoids it. This is a quirk of the host toolchain, not part of the exercise.

---

## Core tasks

All five are expected. Rough guide times are what we think they should take, not a limit.

### 1. Container image (~30 min)

Produce a **single Dockerfile** that builds and runs the service.

- The image that runs in production should contain what it needs to run and not much else.
- Assume this image will be pulled by a cluster you care about.

### 2. A local Kubernetes cluster (~20 min)

Stand up a **multi-node** Kubernetes cluster locally — `kind`, `k3d`, `minikube` with multiple nodes,
or anything equivalent. At least **two worker nodes**.

Script it or document it so that we can reproduce your cluster exactly. We will try.

### 3. Package the service (~60 min)

Package the service for Kubernetes using **either Helm or Kustomize** — your choice, and we don't
prefer one.

> **Please write this yourself.** A `helm create` scaffold, or any equivalent generated boilerplate
> left substantially as generated, scores nothing on this task. We are interested in what you chose to
> include and what you chose to leave out, and generated defaults tell us neither. A minimal set of
> resources you can justify line by line is exactly what we're looking for.

The deployed service must:

- be **reachable from outside the cluster** — how is up to you, as long as you document it;
- have **liveness and readiness configured correctly** for the startup and shutdown behaviour above;
- **stay available across the loss of a single node**, which is why the cluster has more than one;
- have a **greeting name that an operator can change per environment without rebuilding the image**.

### 4. Deploy it with Terraform (~45 min)

Use Terraform to deploy your package to your cluster — the `helm` provider or the `kubernetes` provider,
whichever matches your choice above.

There must be **two environments** — call them `dev` and `prod` — that differ in at least their
greeting name and their replica count, without duplicating the whole configuration.

### 5. Write it up (~20 min)

A file named `DECISIONS.md` in the repository root. This is not documentation of *what* you did — the
commits show that. It is the reasoning. Cover:

- The decisions you're least sure about, and what would change your mind.
- **What you considered and rejected**, and why.
- Anything in this brief you found ambiguous, and the assumption you made.
- What you'd do differently for something genuinely production-facing.
- What you deliberately left out and why.

Candidates consistently under-invest in this file. It carries real weight.

---

## Extensions

Then: **do as many of these as you can in the time you have left, in the order you judge most
valuable — and tell us in `DECISIONS.md` why you chose that order.**

The order you choose, and your reasoning for it, is assessed. It is not a tiebreaker — for a role at
this level, deciding what matters most is the job. There is no expectation that you complete all four.

| | Extension |
|---|---|
| **A** | **CI pipeline.** A GitHub Actions workflow that runs on push and does whatever you think a pipeline for this service should do. |
| **B** | **Observability.** Get the service's metrics into Prometheus, and write **one alerting rule you would actually want to be woken up by**. Demonstrate it firing — `/boom` exists for this. A minimal Prometheus is completely fine; we are not grading the size of the stack. |
| **C** | **GitOps.** Have Flux or Argo CD reconcile the deployment from this repository, so that a commit changes the cluster. If repository authentication turns into a time sink, document the setup you intended and move on — we won't hold the plumbing against you. |
| **D** | **Prove it survives.** Drain one of your worker nodes while the service is under continuous request load, and capture evidence of what happened to those requests. Do the same for a rolling update. Include the evidence. |

---

## If you run out of time

**Stop, and write down where you got to.** A partial submission with a clear account of what's missing,
what you'd do next and what you'd have done differently with more time is a *good* submission. We read
it that way deliberately.

What does not work in your favour is a submission that looks complete but doesn't run.

---

## Submitting

1. Push your work to a branch named `solution` and open a pull request against `main`.
2. **Commit so that each task is identifiable** — we should be able to follow your progress through the
   history. One commit containing everything makes the work much harder to assess.
3. Include everything needed to reproduce your results from a clean clone. We will actually try to run
   it, on a machine that is not yours.

## What happens next

We'll review your submission, then book a **60-minute conversation** about it. In that session we'll
ask you to walk us through what you built, explain the trade-offs, and make a change to it live — so
work in a way you'll be comfortable talking through. Bring the disagreements you have with your own
solution; we're more interested in those than in a defence of it.

If we don't take things further, you'll get specific written feedback either way.

Good luck — and if anything here is unclear or blocking you, please ask rather than guess. Asking is
not a mark against you.
