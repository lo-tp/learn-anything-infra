# learn-anything-infra

Infrastructure and deployment for the Learn Anything product. Everything here is
declared as code: Terraform for the cloud resources, Kubernetes manifests
built with Kustomize (a `base/` plus `overlays/prod` and `overlays/staging`) for
workloads. Hand-edited cloud consoles and imperative `kubectl apply` of
undocumented manifests are out of sync with this repo by definition; treat this
repo as the single source of truth. Nothing here is provisioned with `gcloud`: the
GCP project, its APIs, the cluster, the storage and the budgets are all
Terraform's, and `kubectl` only talks to a cluster it did not create. One thing
Terraform deliberately does not create: the DNS records
([ADR 0004](./docs/adr/0004-dns-stays-at-namecheap.md)).

The Google Cloud SDK **is** installed (`google-cloud-sdk/` in this working tree,
gitignored, and better placed outside the repo). Its permitted jobs are
**identity, tooling, reading, and one bootstrap grant**: signing a human or
workload in, installing components such as `gke-gcloud-auth-plugin`,
`docker-credential-gcloud` for local image pushes, inspecting what exists, and the
single `add-iam-policy-binding` that gave `terraform-local` its first permission —
no other identity could have made it. It is never the thing that creates or
changes a resource: if a `gcloud` command would make something exist in the cloud,
that something belongs in Terraform instead. When a bootstrap act does touch the
cloud, this file and `PLAN.md` say so, so it is not mistaken for drift.

Never run `gcloud auth application-default login` here: it would silently repoint
Terraform from `terraform-local` to a human identity. Use `gcloud auth login`.

Three documents carry the rest, each reached by its own condition:

- [`PLAN.md`](./PLAN.md) — the ordered milestones and what counts as each one
  being done. Read it before starting any infra work, and update it when a
  milestone changes.
- [`CONTEXT.md`](./CONTEXT.md) — the vocabulary: *surface*, *public surface*,
  *internal call*, *service principal*, *foreign record*, *cutover*, *turn-off
  order*. Use these words; the glossary lists what to avoid.
- [`docs/adr/`](./docs/adr/) — why the load-bearing choices went the way they
  did. Read one before reopening a decision it covers.

## The system

Learn Anything spans four repositories. Changes here usually need a matching
change in one of the others; read the neighbour repo's own `AGENTS.md` before
editing it.

| Part | Stack | Local path | GitHub |
|---|---|---|---|
| Backend API | Python, FastAPI | `~/Desktop/Personal/project/python/learn-anything-backend` | https://github.com/lo-tp/learn-anything-backend |
| Frontend | Next.js | `~/Desktop/Personal/project/javascript/learn-anything` | https://github.com/lo-tp/learn-anything-frontend |
| Sandbox | Next.js | `~/Desktop/Personal/project/javascript/learn-anything-sandbox` | https://github.com/lo-tp/learn-anything-sandbox |
| Infrastructure (this repo) | Terraform, Kubernetes | `~/Desktop/Personal/project/learn-anything-infra` | — |

The frontend is the user-facing app; the backend serves its API; the sandbox runs
user code in an isolated Next.js service. Data lives in PostgreSQL (see below).

In production the three are reached as surfaces under one domain:
`learn.lotp.xyz`, `api.lotp.xyz`, `sandbox.lotp.xyz` (plus `staging.` variants).
`blog.lotp.xyz` belongs to something else; see *Foreign record* in
[`CONTEXT.md`](./CONTEXT.md).

## Cross-repo work

- Reach the neighbours through the absolute local paths above; they are checked
  out side by side, not as submodules.
- An API contract change lands in the backend first, then the frontend and
  sandbox consumers. Update the image tag / endpoint config here last, so the
  infra never points at an image that does not implement the contract yet.
- Service discovery, ports, and environment variable names are owned here: when a
  neighbour repo changes one, the matching change belongs in this repo's
  manifests, not in its Dockerfile defaults. Each app's image, however, is built
  in its own repo (`Dockerfile` and build workflow there); this repo consumes
  digests and pins tags.

## Network

This machine is in mainland China, and that changes how the tools fail. Direct
connections to `oauth2.googleapis.com` and `container.googleapis.com` **black-hole**
— they time out rather than refusing — while `registry.terraform.io` and
`storage.googleapis.com` work. The visible symptom is that `terraform init`
succeeds and `terraform plan` hangs.

Route Terraform and `kubectl` through the local HTTP proxy:

```sh
export HTTPS_PROXY=http://127.0.0.1:6152
export HTTP_PROXY=http://127.0.0.1:6152
export NO_PROXY=localhost,127.0.0.1
```

`NO_PROXY` is not decoration: without it, health checks and debugging against the
local dev servers (backend `8001`, sandbox `3001`) go through the proxy and fail.
`make tf-plan` / `make tf-apply` set all three for you. Docker has its own proxy
settings, set in Docker Desktop, not in this shell. CI in GitHub Actions needs
none of this — it runs from GitHub's network.

## Datastore

The backend relies on a PostgreSQL database, run in-cluster as a StatefulSet with
a persistent disk ([ADR 0002](./docs/adr/0002-postgres-in-cluster.md)), backed up
by a nightly `pg_dump` to object storage. Connection settings reach the backend as
environment variables / Kubernetes Secrets, in the plain `postgresql://…` form the
app rewrites to its own driver. The backend keeps its own migrations as the source
of truth for schema, and a migration Job gates every rollout. Infra owns the
server, the volume, the credentials and the dumps — not tables.

## DNS

The domain is registered with Namecheap **and its DNS stays there**: the zone is
not moved to the cloud provider, and the nameservers are never changed.
`learn.lotp.xyz`, `api.lotp.xyz`, `sandbox.lotp.xyz` and the staging hosts are A
records entered by hand, because Namecheap's API allowlists single IPs rather than
ranges and so cannot be driven from CI ([ADR 0004](./docs/adr/0004-dns-stays-at-namecheap.md)).
The record set is still declared here as a Terraform variable, and
`terraform output dns_records` prints exactly what belongs in the dashboard — when
the two disagree, this repo is right and the dashboard is wrong.

`blog.lotp.xyz` is a **foreign record**: read it, preserve it, never edit it. TLS
certificates and Ingress hostnames must match the records declared here.


My domain is lotp.xyz, blog lives at blog.lotp.xyz
