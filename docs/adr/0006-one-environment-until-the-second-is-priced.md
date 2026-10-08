# One environment until the second one is priced

`manifests/overlays/staging/` exists — the same base, everything scaled to zero, the
backup CronJob suspended — but **it has never been applied, and it has no address, no
DNS records and no public surface.** Production is the only environment a browser can
reach. The reason
is arithmetic rather than taste: this cluster's public surface is one global
load-balancing address, and a second environment cannot share it, so "add staging"
means a second address, a second forwarding rule and a second certificate — a second
monthly line — not another host block on the rule that exists.

## Considered options

- **Staging on the same address, as extra hosts in the same URL map.** Rejected:
  a reserved global address is claimed by one Ingress, and the two environments are
  separate Ingress objects in separate namespaces. Folding them into one object
  would also couple their deploy gates, so a staging rollout could block a
  production one.
- **A second GCP project for staging.** Rejected for the same money plus more
  plumbing: a second everything, and this project's budget alerts and cost report
  would stop describing the platform as a whole.
- **Staging as a scale-to-zero deployment on the production address.** Rejected on
  what it costs to be reachable: a cold tier on this load balancer answers 502 for
  minutes and measured ~4.5 minutes zero-to-browser, which is unusable for the
  person doing the testing, and the queueing layer that would fix it costs
  control-plane pods at the same per-pod floor it is trying to avoid (ADR 0001's
  amendment).

## Consequences

- **If it is applied, it is reachable only from inside the cluster** (`kubectl -n
  staging port-forward`, or an `exec` in another pod). That is enough for the job it
  would be for: applying an overlay and checking that it renders and converges.
- **Terraform says so out loud.** Those hostnames are declared as
  `dns_records_deferred`, not left unmentioned: a record that resolves to an
  address with no forwarding rule behind it looks exactly like a broken deploy.
- **The open question is priced, not decided.** Whether staging is worth its line
  is an M9 decision, and the M10 checkpoints will already have measured what the
  first environment costs. Adding it later is one address, one rule, one certificate
  and a set of pods — a Terraform change and a `make dns-check` pass, not a
  redesign.
- **The overlay renders and has never been applied.** `kubectl kustomize
  manifests/overlays/staging` produces 28 objects; the `staging` namespace in the
  cluster is empty. That is consistent with this decision rather than in tension
  with it: the overlay is a reviewed, applyable starting point — the thing that
  exists if the pricing ever says yes — and applying it is precisely the act that
  would start costing money. Staging was never brought up to prove it could be.
