# GKE Autopilot with scale-to-zero, not Cloud Run or Render

Learn Anything has to run somewhere, and the binding constraint is a $300 /
90-day free credit — about $3.33 a day for the whole platform. Cloud Run and a
second Render blueprint would serve all three services for a fraction of that.
We chose GKE **Autopilot** in `asia-east2` anyway, because the point of this work
is to learn Kubernetes properly and the platform cost *is* the price of that; and
we chose Autopilot over Standard deliberately, because Standard's cluster
management fee alone (~$0.10/hour, ~$216 over 90 days) would consume most of the
credit before anything ran.

## Considered options

- **Cloud Run** — cheapest, still Terraform-managed, no cluster to operate.
  Rejected: it optimises away the thing this project exists to teach.
- **Render, extended** — already working for the backend. Rejected: it is
  hand-configured outside the repo, and it is the thing we are leaving.
- **GKE Standard** — full control. Rejected on cost: the management fee dominates
  a budget this small, and nothing here needs the control.

## Consequences

- Autopilot bills on per-pod **requests**, so `requests` are written tight on
  purpose. Sloppy requests are not a warning here; they are the bill.
- Frontend and Sandbox scale to **zero**. An unused app is nearly free, and the
  first visitor pays a cold start of tens of seconds. That is bought knowingly,
  not discovered later; the backend is exempt (see ADR 0003) because its cold
  start would stack on top of multi-minute LLM graphs.
