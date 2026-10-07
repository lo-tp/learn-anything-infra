# learn-anything-infra

Infrastructure and deployment for the Learn Anything product. Everything here is
declared as code: Terraform for cloud and DNS resources, Kubernetes manifests
built with Kustomize (a `base/` plus `overlays/prod` and `overlays/staging`) for
workloads. Hand-edited cloud consoles and imperative `kubectl apply` of
undocumented manifests are out of sync with this repo by definition; treat this
repo as the single source of truth. Nothing here is provisioned with `gcloud`: the
GCP project, its APIs, the cluster, DNS and the budgets are all Terraform's, and
`kubectl` only talks to a cluster it did not create. The one Google-supplied
binary in the design is `gke-gcloud-auth-plugin`, a credential helper `kubectl`
needs to authenticate — it manages nothing.

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

## Datastore

The backend relies on a PostgreSQL database, run in-cluster as a StatefulSet with
a persistent disk ([ADR 0002](./docs/adr/0002-postgres-in-cluster.md)), backed up
by a nightly `pg_dump` to object storage. Connection settings reach the backend as
environment variables / Kubernetes Secrets, in the plain `postgresql://…` form the
app rewrites to its own driver. The backend keeps its own migrations as the source
of truth for schema, and a migration Job gates every rollout. Infra owns the
server, the volume, the credentials and the dumps — not tables.

## DNS

The domain is registered with Namecheap; the DNS zone itself lives in Cloud DNS,
managed by Terraform, so records stay declarative. Nameserver delegation at the
registrar is a human step. Before any delegation change, carry every existing
record into the new zone — `blog.lotp.xyz` in particular. TLS certificates and
Ingress hostnames must match the records declared here.


My domain is lotp.xyz, blog lives at blog.lotp.xyz
