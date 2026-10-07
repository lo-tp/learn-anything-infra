# GKE Autopilot with scale-to-zero, not Cloud Run or Render

Learn Anything has to run somewhere, and the binding constraint is a $300 /
90-day free credit — about $3.33 a day for the whole platform. Cloud Run and a
second Render blueprint would serve all three services for a fraction of that.
We chose GKE **Autopilot** in `asia-east2` anyway, because the point of this work
is to learn Kubernetes properly and the platform cost *is* the price of that; and
we chose Autopilot over Standard because Autopilot bills compute per pod
**request**, which is what makes scale-to-zero honest: an idle namespace costs
nothing instead of holding a node.

## Considered options

- **Cloud Run** — cheapest, still Terraform-managed, no cluster to operate.
  Rejected: it optimises away the thing this project exists to teach.
- **Render, extended** — already working for the backend. Rejected: it is
  hand-configured outside the repo, and it is the thing we are leaving.
- **GKE Standard** — full control, and cheaper on the control plane if you take
  it: the free tier waives the management fee for one **zonal** cluster per
  billing account, and a single Spot node runs this app for ~$10/month. Rejected
  because the compute model is the wrong one here — Standard bills nodes, so
  scale-to-zero has to be engineered (node pool autoscaling, Spot taints,
  system-pod placement) rather than falling out of the requests in the manifests —
  and that plumbing is a second thing to learn at once, not the thing we want to
  learn first.

**Correction, made while applying M1.** The first draft of this ADR said Standard's
management fee alone (~$0.10/hour, ~$216 over 90 days) would consume most of the
credit, as though Autopilot did not have one. It does: GKE bills a cluster-scoped
fee for **both** modes, and the thing that makes the first cluster free is the GKE
free tier — one cluster's fee waived per billing account — not the choice of
Autopilot. Autopilot clusters are also always regional, so the "make it zonal to
stay in the free tier" lever is not available for them. Whether a free-trial
account keeps that waiver is not settled by the sources read for this correction,
and it is worth $2.40/day, so the claim is now a thing to check rather than an
assumption: see the billing-export check added to Consequences.

## Consequences

- Autopilot bills on per-pod **requests**, so `requests` are written tight on
  purpose. Sloppy requests are not a warning here; they are the bill.
- The cluster management fee is expected to be $0 under the free tier and is
  **not** assumed to be. Within a week of the cluster existing, check the billing
  export (or the budget alerts) for a GKE cluster-management SKU. If it is being
  charged, this decision is revisited on price: a zonal Standard cluster with one
  Spot node is the free-tier-shaped answer, or the cluster is deleted and
  re-created from Terraform when needed — ~10 minutes of lead time, which is
  acceptable for a project with no traffic to lose.
- Frontend and Sandbox are meant to scale to **zero**: an unused app is nearly
  free, and the first visitor pays a cold start of tens of seconds. That is bought
  knowingly, not discovered later; the backend is exempt (see ADR 0003) because its
  cold start would stack on top of multi-minute LLM graphs.
- **Correction, found when M3's manifests were applied to the cluster.** A
  HorizontalPodAutoscaler does not deliver this. `minReplicas: 0` is rejected
  unless an Object or External metric is supplied, and even where it is accepted an
  HPA cannot scale *from* zero — with no pods there is no utilisation to act on.
  Waking on request needs something outside the HPA (KEDA with a request-count
  scaler, Knative's activator, or those two tiers on Cloud Run). This is not a
  detail: at Autopilot billing floors, pinning those two tiers at one replica costs
  roughly $25/month more than letting them sleep, which is over the budget this ADR
  was written to fit. The options and the arithmetic are at PLAN.md M3, where the
  choice is recorded as open; the choice of Autopilot itself is not reconsidered
  here, because the reason for it — learning Kubernetes on the tier where state
  actually lives — is unaffected.

## Amendment (2026-10-08): the scale-to-zero half of this decision has no mechanism here

The first half — Autopilot, pay-per-pod, small pinned workloads — is holding, and
the two-tier floor of backend + database is what was measured. The second half,
"and the idle tiers scale to zero *and come back on demand*", turned out to be a
claim about a mechanism this platform does not provide for browser traffic.

A global Application Load Balancer sends requests to a NEG. Nothing queueing in
front of the pod means nothing that can hold a request while a pod starts: a scaler
can only read ALB request metrics, which arrive minutes late, and even after a pod
is Ready its NEG takes 1–4 more minutes to attach. Measured end to end: from zero
replicas to a 200 in a browser, about four and a half minutes. A visitor experiences
that as a broken site, which is exactly what one did (a 502 at `learn.lotp.xyz`).

So: zero is still the right *idle* state for those tiers in principle, and this
decision's cost argument for preferring Autopilot stands; but "wake on request"
requires either a queueing layer in the cluster (Knative's activator, KEDA's HTTP
add-on — whose own control-plane pods cost about what they save, per PLAN.md M3)
or those tiers living somewhere that does queue (Cloud Run, PLAN.md M3 option C).
Until that is chosen, the production overlay pins one replica of each with its
reason in `manifests/overlays/prod/replica-floor.yaml`. This ADR's status is
unchanged in intent and explicitly unfinished in mechanism.
