# learn-anything-infra

Infrastructure and deployment for the Learn Anything product. Everything is
declared as code: Terraform for the cloud resources, Kubernetes manifests built
with Kustomize (a `base/` plus `overlays/prod` and `overlays/staging`) for
workloads. A hand-edited cloud console or an imperative `kubectl apply` of an
undocumented manifest is out of sync with this repo **by definition**: this repo is
the single source of truth.

**If `AGENTS.local.md` sits next to this file, read it as well.** It holds what
belongs to one machine — where the four repositories are checked out, the proxy
port, credential and SDK locations, network quirks of the network this machine is
on. It is untracked, and nothing here may depend on it: a fact that matters to the
deployment belongs in this file, a plan file, or an ADR.

Two things Terraform deliberately does not create: the **DNS records**
([ADR 0004](./docs/adr/0004-dns-stays-at-namecheap.md) for why; the records are a
Terraform variable and `terraform output dns_records` prints the rows) and the
**BigQuery billing export**, a one-time console setting that `make cost-report`
reads and that backfills nothing.

## Rules that are not discoverable from the code

- **`gcloud` creates nothing.** Its permitted jobs are identity, tooling, and
  reading — plus the one bootstrap grant that no other identity could have made. If
  a `gcloud` command would make something exist in the cloud, that thing belongs in
  Terraform instead. When a bootstrap act does touch the cloud, Step 0 of the plan
  says so, so it is not mistaken for drift.
- **Never run `gcloud auth application-default login`**: it silently repoints
  Terraform from `terraform-local` to a human identity. Use `gcloud auth login`.
  The Makefile pins Terraform's credential (`GCRED`) so the two never trade places.
- **`kubectl` uses the human identity on purpose.** `make kcreds` writes
  `.kubeconfig-gke` for it; the reason is a tool failure, and
  `scripts/ci-kubeconfig.sh` carries both halves of the identity design (a human
  through gcloud, CI through application default credentials — neither a fallback
  for the other).
- **Never hand-scale.** Replicas are set in `overlays/prod/replica-floor.yaml`, by
  decision (ADR 0001's amendment). A hand-run `kubectl scale` is drift the next
  deploy removes.
- **Never pass an image on a command line.** What production runs is `images:` in
  `manifests/overlays/prod/kustomization.yaml`, always by digest; `git diff` of that
  block is the approval. That is also why the migration Job and the Deployment
  cannot drift apart.
- **Never let a second `terraform apply` create a second cluster.** An interrupted
  apply leaves the cluster real, outside state, and a stale lock in the state
  bucket: `terraform force-unlock <id>`, then `terraform import`, then apply. The
  findings are in [M1](./docs/plan/m01-terraform-foundation.md).
- **Never edit `blog.lotp.xyz`.** It is a *foreign record*
  ([CONTEXT.md](./CONTEXT.md)); read it, preserve it.
- **An unreachable hostname is a DNS or certificate question before it is a code
  question.** `make dns-check` compares Terraform, the live Ingress, what the
  registrar answers, and the certificate's actual SANs, and exits non-zero on a
  disagreement.

## Network

This machine is in mainland China, and that changes how tools fail rather than what
they do. Route Terraform and `kubectl` through the local HTTP proxy (the port is
this machine's; the Makefile takes it from `GCP_PROXY`):

```sh
export HTTPS_PROXY=http://127.0.0.1:6152
export HTTP_PROXY=http://127.0.0.1:6152
export NO_PROXY=localhost,127.0.0.1
```

`NO_PROXY` is load-bearing: without it, health checks against the local dev servers
(the ports the app repositories configure for themselves) go through the proxy and
fail. `make tf-*` sets all three. The symptom of forgetting them is a
`terraform init` that succeeds and a `terraform plan` that hangs — some Google
endpoints black-hole rather than refuse. Docker has its own proxy settings (Docker
Desktop, not this shell), and CI in GitHub Actions needs none of this.

Inside the cluster the same trap is one level down: with private nodes, pods have no
internet egress unless the VPC has a Cloud NAT gateway. **Measure egress from inside
a pod** — the laptop's reachability says nothing about it — and see
`gcp/network.tf` first, then the load balancer's request timeout, whose 30-second
default turned a still-running request into a Google-authored 502
(`manifests/base/backend-config.yaml` raises the ceiling).

## Deploys

A deploy is an order, not a command: **migrations first, then the workloads, then
the rollout.** `make deploy` is that order; its point is that a failed migration
stops the deploy with the Job's log printed and nothing else touched, so what was
serving keeps serving. `kubectl apply -k` on its own skips the gate — use it only
for changes that cannot touch the schema.

- **Convergence is checkable**: `kubectl diff` against
  `kubectl kustomize manifests/overlays/prod` should be empty. A non-empty diff is
  an unapplied change or something edited in the cluster; both are worth knowing
  before the next deploy, and CI fails on it.
- **CI applies the manifests; the merge into `release` is the authority.** Merging
  `main` into an app repository's `release` branch is the act that ships: `deliver.yml`
  pins the published digest as a commit and dispatches `deploy.yml` (ADR 0007). No
  image is ever passed on a command line. Secrets are rendered from Secret Manager at
  deploy time — no secret value is ever in this repo, and `make secrets` says out
  loud when an entry still holds a placeholder (`make secret-hygiene` proves the
  rest).
- **Rollback is `git revert` of the pin commit, pushed** — the deploy runs again
  against the previous digests. Migrations are forward-only, so a rollback that
  crosses a migration is a fix-forward, not a revert.
- **Image contracts are enforced by the cluster, not by review**: a numeric `USER`
  (`runAsNonRoot` is verified numerically), linux/amd64, and a dependency-free
  readiness route. A Dockerfile that ignores them fails at pod start.

## Working across the four repositories

Learn Anything spans four repositories, checked out as ordinary clones rather than
submodules. Read a neighbour's own `AGENTS.md` before editing it.

| part | canonical source |
|---|---|
| Backend API (FastAPI) | [`lo-tp/learn-anything-backend`](https://github.com/lo-tp/learn-anything-backend) |
| Frontend (Next.js) | [`lo-tp/learn-anything-frontend`](https://github.com/lo-tp/learn-anything-frontend) |
| Sandbox (Next.js) | [`lo-tp/learn-anything-sandbox`](https://github.com/lo-tp/learn-anything-sandbox) |

**To reach a neighbour from here:** they live under one parent directory, grouped by
language (`python/`, `javascript/`) in this checkout. Find one by repository name
under the parent of this repo — `ls ..` — and clone it if it is not there. Absolute
paths belong to a machine, so they are not written here: on this machine they are in
`AGENTS.local.md`.

- An API contract change lands in the backend first, then its consumers, and the
  image pin here changes **last** — this repo never points at an image that does not
  implement the contract yet.
- Service discovery, ports and environment-variable names are owned here; an app's
  image is built in its own repo. This repo consumes digests.
- **Only the `release` branch of an app repository publishes an image, and the
  merge into it is what ships one.** `main` is checked (lint, typecheck, unit tests)
  and never builds; `release` is protected and merge-only, so the commit a pin
  comment names stays reachable on `main`. Pushing there delivers end to end — build,
  smoke test, publish, pin, deploy ([ADR 0007](./docs/adr/0007-the-merge-into-release-is-the-approval.md)).

## On a machine that has never run this

Everything below is a Makefile variable, so nothing here is a fact about my laptop:

| variable | what it is | default |
|---|---|---|
| `GCP_PROXY` | the HTTP proxy that reaches Google endpoints from this network | `http://127.0.0.1:6152` |
| `GCRED` | the service-account key Terraform signs with | `~/.config/gcp/learn-anything-510905.json` |
| `SDK` | where `gcloud` and `gke-gcloud-auth-plugin` live | `./google-cloud-sdk/bin` — a gitignored directory, deliberately outside the repo; set `SDK=/path/to/bin` if yours is installed elsewhere |
| `KUBECONFIG` | the generated cluster credentials file | `./.kubeconfig-gke`, written by `make kcreds` |
| `ROOT`, `NS`, `ENV` | which Terraform root, namespace and overlay a target acts on | `gcp`, `learn-anything`, `prod` |

`make help` prints them with their current values, and `AGENTS.local.md` records
what this machine uses. A fresh machine needs the SDK installed, one key file in
place, and a logged-in human (`gcloud auth login`) before any `make k*` target
works.

## Where to read next

| when | reach for |
|---|---|
| starting or changing infra work | [`docs/plan/index.md`](./docs/plan/index.md), then the milestone file you are touching |
| reopening a design choice | [`docs/adr/`](./docs/adr/) — one ADR per load-bearing decision |
| any word with a specific meaning here | [`CONTEXT.md`](./CONTEXT.md): *surface*, *public surface*, *internal call*, *foreign record*, *cutover*, *turn-off order* |
| anything touching the database | ADR 0002 and [M4](./docs/plan/m04-postgres-in-cluster.md); the `psql` and port-forward recipes are comments in `manifests/base/database.yaml` |
| a local image build or pull | [`docs/ops/podman.md`](./docs/ops/podman.md) — nothing in the deployment depends on the local machine |
| what this repo is, to a newcomer | [`README.md`](./README.md); keep it descriptive, never status-carrying |

## A state that is normal, not a failure

An **idle Autopilot cluster has no nodes.** `kubectl get nodes` returning `No
resources found` is the expected state; nodes appear when a workload schedules and
disappear again. Reachability of the control plane from the network you are on is
machine-specific and belongs in `AGENTS.local.md`.
