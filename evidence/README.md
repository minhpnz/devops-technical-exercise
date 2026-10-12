# Evidence

Raw output from running this repository on one machine, kept so the claims in
`DECISIONS.md` can be checked rather than taken on trust. Start with the table;
each folder holds the output for one task.

**Machine:** macOS 26.6 (Intel, x86_64), Docker Engine 20.10.12 with a 6 vCPU / 6 GB VM,
kind v0.33.0. Times in logs are UTC unless the line says otherwise.

**Conventions**

- Text logs show the command, its output and `[exit N · time]` for every step,
  so each line of output can be traced to the command that produced it.
- Nothing is edited by hand. A step that needed re-running was re-run as a whole.
- Screenshots sit next to the logs they illustrate.
- No credentials, kubeconfigs or Terraform state are stored here.

## Index

Listed in the order the work was done. GitHub sorts folders alphabetically, so
use this table for the reading order.

| Phase | Folder | What it shows | Key result |
|---|---|---|---|
| 1 | [`docker-image/`](docker-image/) | The image handles SIGTERM the way the app intends: it reports not-ready, keeps serving for `SHUTDOWN_DELAY_SECONDS`, then drains in-flight requests | A 15 s `/work` request started before `docker stop` returned `200`; `closing listener` came 10 s after `signal received`; the container exited `0` |

## docker-image/

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
