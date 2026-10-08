# learn-anything-infra

Deployment for [Learn Anything](https://learn.lotp.xyz): a FastAPI backend, a
Next.js frontend, and a Next.js sandbox that runs user code. All three are served
from one Google Kubernetes Engine cluster, declared here as code — Terraform for
every cloud resource, Kustomize for every cluster object.

The interesting part is not the topology, which is ordinary. It is that the design
was chosen under two constraints that are visible in every file here: **a dated
budget** (a $300 trial credit that expires 2027-01-06, which sets a hard ceiling of
$3.30/day) and **a network that fails selectively** (this machine is in mainland
China, where some Google endpoints answer and others black-hole). Most of what the
docs record is what those two constraints did to a plan that looked reasonable on
paper.

## The shape

One cluster, one global Application Load Balancer, one reserved IP, one
Google-managed certificate covering three hostnames. Routing is by `Host` header.

```
                    ┌─ learn.lotp.xyz     → frontend  (Next.js)
DNS (Namecheap) ────┼─ api.lotp.xyz       → backend   (FastAPI)
   one A record     └─ sandbox.lotp.xyz   → sandbox   (/slides only)
        │
   one global IP ── one URL map ── three backends ── GKE Autopilot, asia-east2
                                                   │
                                                   ├─ PostgreSQL StatefulSet + 5 Gi disk
                                                   ├─ nightly pg_dump → Cloud Storage
                                                   └─ one replica per tier, by decision
```

`sandbox.lotp.xyz/` returns 404 by design: only `/slides` is routed there, because
the sandbox is reached by the browser at `/slides/{id}` and by the backend *inside*
the cluster. `/api/compile` is deliberately never public.

There is one environment. `overlays/staging/` exists — everything at zero, the
backup suspended — but it has never been applied, and it has no address and no
records: a second environment would be a second address and a second monthly line,
which is a decision rather than a config change
([ADR 0006](./docs/adr/0006-one-environment-until-the-second-is-priced.md)).

## What is *not* in this repo

Four things are missing on purpose, and each has a reason that a reader would
otherwise guess wrong:

| not here | where it is | why |
|---|---|---|
| secret **values** | Secret Manager | `make secrets` renders the cluster Secrets from them; no credential is ever committed, and `make secret-hygiene` proves it |
| DNS records | Namecheap, typed by hand | its API allowlists single IPs, not ranges, so CI cannot drive it ([ADR 0004](./docs/adr/0004-dns-stays-at-namecheap.md)) — the record set is still *declared* here, and `terraform output dns_records` prints exactly what belongs in the dashboard |
| the billing export | one console setting | there is no API for it and it is not backfilled; `make cost-report` reads it |
| the app images | built in each app's repo | this repo consumes digests and pins them; the Dockerfiles live with the code |

## How a change reaches production

An order, not a command. Every step is enforced by a workflow or a script, not by
discipline:

1. **Build and smoke-test in the app's own repository.** The workflow publishes to
   Artifact Registry only *after* the image answered a real request — `/health`,
   the auth redirect to `/en/login`, `/api/compile`. An image that never served a
   request never gets a tag.
2. **Pin it here, by digest.** `pin-image.yml` opens a pull request against one
   reused branch; `images:` in `manifests/overlays/prod/kustomization.yaml` is the
   record of what production runs, and **`git diff` of that block is the
   approval**. Nothing is ever passed on a command line, which is why the Job that
   migrates and the Deployment that serves cannot drift apart.
3. **CI deploys: migrations first.** `scripts/deploy.sh` runs the migration Job,
   and a failure stops there with the Job's log printed and nothing else touched —
   what was serving keeps serving. Then apply, then rollout.
4. **Convergence is checked, not assumed.** The workflow fails if `kubectl diff`
   against the rendered overlay is not empty. A non-empty diff means either an
   unapplied change or something edited in the cluster; both are facts worth having
   before the next deploy.

## The commands worth knowing

`make` alone prints the list. What each one *proves* matters more than what it
runs:

| | proves |
|---|---|
| `make tf-plan` / `tf-apply-yes` | the cloud matches `gcp/` — and, since the state bucket exists, that it matches *versioned* state |
| `make deploy` | the schema gate holds before anything serving is touched |
| `make secrets` | every Secret the workloads read exists, and it says out loud when one still holds a placeholder |
| `make dns-check` | Terraform, the live Ingress, what the registrar answers, and the certificate's actual SANs agree |
| `make acceptance` | a real session completes through the public surface: register → login → plan → slides |
| `make restore-drill` | the newest dump actually restores, and its table shapes match the live database |
| `make cost-report` | what the platform costs, **with cost and credits printed separately** — the invoice being small is not the same fact as the platform being cheap |
| `make secret-hygiene` | no secret value in any repo or running image, and shared pairs match across services by hash |

## Reading order

| file | for |
|---|---|
| [`AGENTS.md`](./AGENTS.md) | how to operate this: the proxy environment, why `gcloud` creates nothing, why `kubectl` and Terraform use different identities, the failure modes that look like something they are not |
| [`CONTEXT.md`](./CONTEXT.md) | the vocabulary — *surface*, *public surface*, *internal call*, *foreign record*, *cutover*, *turn-off order*, *replica floor* vs *billing floor* |
| [`docs/adr/`](./docs/adr/) | why the load-bearing choices went the way they did, including the ones where measurement overturned the design |
| [`PLAN.md`](./PLAN.md) | a working document: the milestones, each with the condition that said it was done, and the dated findings of what actually happened |

The findings in `PLAN.md` are the honest record of a plan meeting reality: an
`ingress.kubernetes.io/force-ssl-redirect` annotation that the controller ignores
because it is nginx's spelling; a woken tier answering 502 for minutes after its
pod is Ready because the NEG attaches late; a scale-from-zero design that does not
survive an Application Load Balancer with no queueing mechanism, and the arithmetic
that showed the alternative cost as much as the thing it saved.

## What works, and what is open

Verified end to end through the public surface as of 2026-10-08: registration and
login across subdomains, the session list, slides rendering as framed documents with
their stylesheets and maths, the migration gate in both directions, a real
`pg_restore` of a nightly dump, and agreement between Terraform, the load balancer,
the registrar and the certificate.

Open, and named rather than hidden:

- **The product cannot yet complete a new session.** The model endpoint is
  unconfigured in Secret Manager, and separately the provider returns
  `403 unsupported_country_region_territory` for requests leaving `asia-east2` —
  so a key alone is not the fix; the endpoint has to be reachable from that region.
- **Cutover is incomplete.** The old Render services still run; stopping them is a
  dashboard action. Nothing carries over from that database
  ([ADR 0005](./docs/adr/0005-no-render-data-carries-over.md)).
- **Cost is not yet measured.** `make cost-report` exits 2 until the billing export
  is switched on, and nothing before that day is backfilled. The plan's cost tables
  are estimates and say so; the checkpoints in M10 replace them with billed figures.

## Four repositories

| part | stack | repository |
|---|---|---|
| Backend API | Python, FastAPI | [lo-tp/learn-anything-backend](https://github.com/lo-tp/learn-anything-backend) |
| Frontend | Next.js | [lo-tp/learn-anything-frontend](https://github.com/lo-tp/learn-anything-frontend) |
| Sandbox | Next.js | [lo-tp/learn-anything-sandbox](https://github.com/lo-tp/learn-anything-sandbox) |
| Infrastructure | Terraform, Kubernetes | this repository |

Contract changes land in the backend first, then its consumers, and the image pin
here changes last — so this repo never points at an image that does not implement
the contract yet.
