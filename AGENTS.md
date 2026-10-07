# learn-anything-infra

Infrastructure and deployment for the Learn Anything product. Everything here is
declared as code: Terraform for cloud/DNS resources, Kubernetes manifests/Helm
for workloads. Hand-edited cloud consoles and imperative `kubectl apply` of
undocumented manifests are out of sync with this repo by definition; treat this
repo as the single source of truth.

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

## Cross-repo work

- Reach the neighbours through the absolute local paths above; they are checked
  out side by side, not as submodules.
- An API contract change lands in the backend first, then the frontend and
  sandbox consumers. Update the image tag / endpoint config here last, so the
  infra never points at an image that does not implement the contract yet.
- Service discovery, ports, and environment variable names are owned here. When a
  neighbour repo changes one, the corresponding change belongs in this repo's
  manifests, not in its Dockerfile defaults.

## Datastore

The backend relies on a PostgreSQL database. Connection settings reach the
backend as environment variables / Kubernetes Secrets; the backend keeps its own
migrations as the source of truth for schema. Infra owns provisioning,
connection strings, credentials, backups, and connectivity — not tables.

## DNS

The domain is registered with Namecheap. Manage DNS through Terraform so records
stay declarative; keep the registrar account and any nameserver delegation as the
human-owned step. TLS certificates and ingress hostnames must match the records
declared here.
