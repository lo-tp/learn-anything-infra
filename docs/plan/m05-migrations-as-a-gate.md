# M5 — Migrations as a gate

← [plan index](./index.md) · [M4](./m04-postgres-in-cluster.md) · next [M6](./m06-one-public-surface-three-hostnames-real-certificates.md)

A `Job` that runs `alembic upgrade head`, applied before the Deployment rolls,
so a migration failure blocks the rollout instead of restarting a pod that cannot
reach its schema.

**Done when:** a deliberately broken migration revision makes the deploy fail with
a visible Job log, and the previous Deployment is left serving.

**Status: applied, and the gate works in both directions (2026-10-07).**
Production is running: one backend pod (image digest `dd32533a…`, built by CI from
`fdb0b377`) serving `/health` through its own readiness probe, next to the
database. The two frontend tiers are at zero (no images yet — see below).

The mechanism is `scripts/deploy.sh` (and `make deploy`), in that order: read the
image the overlay names → run *that* image's `alembic upgrade head` as a Job and
wait → only then `kubectl apply` the overlay and wait for the rollout. The image
comes out of `manifests/overlays/prod/kustomization.yaml` rather than from an
argument, so what gets migrated and what gets deployed cannot disagree.

Gate evidence:

- **Positive**: `migrate-d1e0c6075189-…` completed, then the Deployment rolled
  (`deployment "backend" successfully rolled out`), then `curl` through the
  Service returned `{"status":"ok"}` and the migration log showed the schema at
  head. Re-running the same deploy applied 12 unchanged objects and said so.
- **Negative**: a revision whose `upgrade()` raises was built into an image
  (`local-m5-probe`) and pointed at in the overlay. The deploy stopped at the
  gate with the log naming the file and the line
  (`alembic/versions/zzz_m5_probe_fails.py, line 17 … fails on purpose`), exited
  non-zero, and the live Deployment still pointed at the previous digest with
  `ready=1`. The probe revision was never committed and has been deleted; the
  image stays in the registry as a rejected artifact.
- Converged state is checkable in one command: `kubectl diff` against
  `kubectl kustomize manifests/overlays/prod` is empty.

What the design had to learn about Jobs, which is all in `deploy.sh` comments:

- **A Job's name must change when anything that runs changes** — its pod template
  is immutable. The name is therefore `migrate-<12 hex of image digest>-<6 hex of
  the rendered Job template>`; editing the Job definition alone would otherwise
  make the next deploy die on "field is immutable".
- **Re-applying an unchanged Job is also rejected**, because GKE's own defaults
  (dropping `NET_RAW`) make the stored object differ from the file. So a Job that
  already completed is reported and skipped, and one that already failed is
  reported and stops the deploy: a schema error is not transient, and re-running a
  completed migration buys nothing.
- **The image's `USER` has to be numeric.** `USER app` is a name Kubernetes
  cannot resolve, so `runAsNonRoot: true` — the contract the base manifests
  assert — fails as `CreateContainerConfigError: image has non-numeric user (app)`.
  The backend now uses `USER 10001` (backend repo `d93da1a`). The instruction for
  the two images M2 has not written yet: numeric uid, and no `runAsUser` in the
  manifests, so the uid is spelled once.
- **A `:placeholder` image is now visibly wrong, not merely unbuilt.** One aborted
  deploy left a migration Job pulling `learn-anything-backend:placeholder` into
  ImagePullBackOff, which is the correct symptom for "the overlay never said what
  to run". Worth remembering when something looks like a registry problem.

Two things that are *not* finished inside this milestone, one of which moved while
this was being written:

- **The image production runs is the pipeline's.** `PROMPTS_TOKEN` is set, CI builds
  and pushes `sha-<commit>`, and the production digest is one of those; the three
  laptop-built tags were deleted so no future deploy can reach for them. The gate
  itself ran against that CI image: `migrate-dd32533ac7d8-…` completed, the
  Deployment rolled onto it, `/health` answered, and `alembic_version` still reads
  `c3d4e5f6a7b8`.
- **`OPENAI_API_KEY` in Secret Manager is still a placeholder**
  (`REPLACE_ME-openai-api-key-not-yet-supplied`). The pod starts because the
  variable exists; the first real LLM call would not work. `make secrets` prints
  that fact rather than swallowing it. M8 needs the real key.
- Frontend and sandbox images do not exist (M2 continues), so their Deployments are
  patched to zero replicas in the production overlay (`asleep.yaml`) rather than
  left to schedule pods that cannot pull. Their placeholder HPAs were removed: an
  autoscaler that insists on at least one replica contradicts the scale-from-zero
  choice in ADR 0001, and a KEDA ScaledObject expects to find the Deployment at
  zero.
