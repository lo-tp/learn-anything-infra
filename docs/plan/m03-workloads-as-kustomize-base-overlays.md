# M3 — Workloads as Kustomize base + overlays

← [plan index](./index.md) · [M2](./m02-images-this-is-where-the-work-actually-is.md) · next [M4](./m04-postgres-in-cluster.md)

`base/` plus `overlays/prod` and `overlays/staging`. Deployments, Services,
HPAs, resource requests/limits, probes.

- **Backend**: `replicas: 1`, `strategy: Recreate`, never scaled to zero
  ([ADR 0003](../adr/0003-single-replica-backend.md)). Probes on `GET
  /health` — which is deliberately dependency-free, so a slow database is not
  interpreted as a dead pod.
- **Frontend and Sandbox**: `HPA minReplicas: 0`, so an unused app is nearly
  free. The first visitor pays a cold start; that trade is part of
  [ADR 0001](../adr/0001-gke-autopilot-with-scale-to-zero.md).
- Tight `requests` on every container, because Autopilot bills on requests.

**Done when:** `kubectl kustomize overlays/prod` renders, applies cleanly, and
`kubectl get pods` shows the backend Ready while the other two sit at zero.

**Status: written and validated; the production overlay is now applied (see [M5](./m05-migrations-as-a-gate.md),**
`2026-10-07`). `manifests/` holds `base/` plus `overlays/prod` and
`overlays/staging` — Deployments, Services, requests and limits, probes, and the
data tier. Both overlays render, and both pass `kubectl apply --dry-run` against
the live cluster with no errors. In production the backend runs and reports Ready
through its own probe; the frontend and sandbox are at zero replicas by patch
(`asleep.yaml`) — the gate clause "the other two sit at zero", arrived at by a
different route than the HPA placeholder originally imagined. Their images now exist
and are pinned by digest, so what still keeps them from serving is the **wake-up
floor** (`replica-floor.yaml`, option D below — chosen on 2026-10-08, after a
browser visit to `learn.lotp.xyz` returned the 502 that an un-woken zero produces).
KEDA is not installed and is no longer the plan for these tiers; see the option
table and ADR 0001's amendment for why. M6's ingress and hostnames are done. The
HPA placeholders are gone from both: a `minReplicas: 1` HorizontalPodAutoscaler
forbids the zero that ADR 0001's design requires, and KEDA expects to own that
range. Under option (D) there is nothing left to install for this gate: the tiers
run at one replica and the wake-up question is closed until a bill or a load reopens
it (M10, and the note above about deciding again rather than silently). What remains
before a real session works is a named value, not a named object: a real
`OPENAI_API_KEY` (a placeholder until M8). Staging is
apply-able and deliberately not runnable: no images built with staging origins, no
hostnames — which is what `overlays/staging/asleep.yaml` states rather than hides.

### The scale-to-zero design does not survive contact with the API

The cluster rejected it, which is the useful kind of surprise:

```
HorizontalPodAutoscaler "frontend" is invalid:
  spec.minReplicas: Invalid value: 0: must be greater than or equal to 1,
  spec.metrics: Forbidden: must specify at least one Object or External metric
                to support scaling to zero replicas
```

Two facts, and the second is the one that matters even if the first is worked
around:

1. `minReplicas: 0` requires an **Object or External** metric. A CPU- or
   memory-target HPA cannot go to zero at all.
2. An HPA cannot scale **from** zero: with no pods there is no utilisation to act
   on. Something outside the HPA has to start the pods when a request arrives.

The cost of not solving it is not small, at the Autopilot billing floor (requests
rounded up in 250 mCPU steps, with a minimum pod size; the unit rates below are
list-rate estimates back-derived from Google's own cost calculator and are replaced
by the invoice in [M10](./m10-verify-the-budget-claim-with-numbers.md)):

| state | estimate |
|---|---|
| one pod at the billing floor (250m CPU / 0.5 GiB) | ~$0.018/hr ≈ **$12.7/month** |
| backend only (frontend + sandbox asleep) | ~$12.7/month |
| all three pinned at 1 replica | ~$38/month — **over the $35 ceiling** |

So scale-from-zero is not a nicety of this design; the budget depends on it. The
options, in the order I would weigh them:

- **(A) KEDA + an external request-count scaler** (Prometheus/Stackdriver). Keeps
  everything in the cluster and teaches the most; the KEDA controller is itself a
  always-on pod, i.e. part of a floor-sized pod's worth of cost.
  **Corrected after choosing it, before installing it:** the arithmetic is worse
  than "part of a floor-sized pod". KEDA's HTTP add-on ships three deployments
  (interceptor, scaler, operator) with a combined default of 8 replicas, and
  GKE's own addon config runs a 3-replica operator plus a 1-replica interceptor
  and scaler. At the floor price in the table above that is ~$100/month for the
  defaults, and ~$25–38/month even after shrinking every one of them to a single
  replica — i.e. the same order of cost as **(D)**, which was supposed to be the
  expensive option. Nothing was installed; this is the manifest replica counts
  multiplied by the billing floor, not an invoice. It does not rule (A) out, but
  it moves the comparison: (A) buys scale-from-zero while spending most of what
  it saves, and **(C)** is now the only option in that table that is clearly
  cheaper while idle. Decide again before M8, not silently in the manifests.
- **(B) Knative on GKE.** Purpose-built scale-from-zero with a request-queueing
  activator; a second system to learn, and its own control-plane pods.
- **(C) Those two tiers on Cloud Run, backend stays on GKE.** Cheapest when idle
  and wakes on request; ADR 0001 rejected Cloud Run *for the whole system* because
  it optimises away the Kubernetes learning, and this keeps the learning on the
  tier where state actually lives.
- **(D) Pin all three at 1.** Simplest, and it breaks the $35 ceiling above.
  **← chosen, 2026-10-08.** Not because it is cheap: because (A) cannot deliver a
  wake a browser would not notice, (B) adds a second control plane whose own pods
  sit at the same billing floor, and (C) would put the two UI tiers on a platform
  this project is here to learn past. The cost is accepted out loud, in the alert
  threshold and in `replica-floor.yaml`, rather than argued away.

**Measured, which is what (D) is now and why it is still not a decision.** A
browser at `learn.lotp.xyz` got a 502 because the URL map's backend had no
endpoints: the design's zero, with no wake mechanism installed. Going from zero to
a 200 in the browser took **about four and a half minutes** — schedule, pull,
readiness, then the 1–4 minutes for the NEG to attach. That is the number every
option has to be judged against, and it is not a Kubernetes tuning problem: a
global Application Load Balancer hands requests to a NEG with nothing queueing in
front of it, so any scaler here reacts to ALB metrics that are already minutes
late. `(A)` cannot fix a cold start, only pay for a control plane that tries; `(B)`
and `(C)` are the two that actually queue.

So the production overlay now pins one replica of each tier with the reason written
where the knob is, and the remaining choice is narrower than the list above: **(C)
or (D)**, at M8, with M10's first bill read in hand. Four always-on pods is
roughly double the measured two-pod run-rate — order ~$1.7/day, ~$50/month —
inside the trial credit's ceiling, above the $35 target, and irreducible by
lowering requests, because Autopilot bills a 0.25 vCPU / 1 GiB floor per pod
whatever the container asks for.

The manifests carry `minReplicas: 1` as a **placeholder**, with that word in the
comment, so the compromise is visible where the decision has to be acted on rather
than buried in a document. This is a decision for you: **(A), (B), (C) or (D)**.

Other things the apply surfaced, recorded so they are not rediscovered:

- The backend refuses to start without `DATABASE_URL`, `JWT_SECRET` and
  `OPENAI_API_KEY` — three Secrets before a pod is Ready, and `/health` answers
  without touching the database, which is exactly why the readiness probe uses it.
- `.env.example` in the backend lists `DATABASE_URL` and `JWT_SECRET` but not
  `OPENAI_API_KEY` / `OPENAI_BASE_URL` / `LLM_MODEL`: it is behind the code.
- Pod security contracts in the manifests (`runAsNonRoot: true`, capabilities
  dropped) are assertions about images two of which do not exist yet; the
  frontend and sandbox Dockerfiles must set a non-root user or their pods will not
  start.
