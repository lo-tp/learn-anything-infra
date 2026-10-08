# learn-anything-infra

Infrastructure and deployment for the Learn Anything product. Everything here is
declared as code: Terraform for the cloud resources, Kubernetes manifests
built with Kustomize (a `base/` plus `overlays/prod` and `overlays/staging`) for
workloads. Hand-edited cloud consoles and imperative `kubectl apply` of
undocumented manifests are out of sync with this repo by definition; treat this
repo as the single source of truth. Nothing here is provisioned with `gcloud`: the
GCP project, its APIs, the cluster, the storage and the budgets are all
Terraform's, and `kubectl` only talks to a cluster it did not create. Two things
Terraform deliberately does not create: the DNS records
([ADR 0004](./docs/adr/0004-dns-stays-at-namecheap.md)), and the **BigQuery
billing export** — a one-time console setting (Billing → Budgets & costs → Billing
export → *BigQuery usage export* → this project) that M10's `make cost-report`
reads. Nothing is backfilled into it, so the day it is enabled is the first day
the platform is measurable.

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
  milestone changes. Its `**Status: done…**` paragraphs are **dated findings**, not
  current status: what production runs is `images:` in
  `manifests/overlays/prod/kustomization.yaml`, and nothing in PLAN.md is
  authoritative about digests.
- [`README.md`](./README.md) — the front door for a human reader. Keep it
  descriptive rather than status-carrying: it may name what is open, but it must
  not become a second place that claims what is deployed.
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
| Infrastructure (this repo) | Terraform, Kubernetes | `~/Desktop/Personal/project/learn-anything-infra` | https://github.com/lo-tp/learn-anything-infra |

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

The cluster has its own version of the same trap, and it looks identical: with
`enable_private_nodes`, pods have **no internet egress unless the VPC has a Cloud
NAT gateway**, and the symptom is a timeout to any non-Google host — from inside a
pod, `api.openai.com` never completes a TCP connection while
`storage.googleapis.com` answers in a tenth of a second. M8 found it by measuring
from a pod instead of reasoning from the laptop. `gcp/network.tf` carries the
router and the NAT; if a workload ever needs an external API, that is the first
line to check, and the second is the load balancer's request timeout: at its
30-second default it turned a still-running request into a Google-authored 502.
`manifests/base/backend-config.yaml` raises it to 600 s — nothing is billed for the
number itself, what a longer ceiling costs is held request capacity and extra
retries — and the limits that bind before it are the apps' own client timeouts.

## Container images: podman, not Docker

Images on this machine are built and run with **podman**. Do not reach for `docker`
— there may be no daemon, and podman is what holds the local images and the
dev containers (`learn-anything-db`, `subconverter`).

The podman VM is a separate network from the laptop, and it is the same wall as the
"Network" section: from inside the VM, `registry-1.docker.io`, `mirror.gcr.io` and
`asia-east2-docker.pkg.dev` all time out, while `storage.googleapis.com` answers —
so the failure looks selective rather than total. The laptop's proxy **is** reachable
from the VM as `host.containers.internal:6152`, so the pull path is fixed by giving
the unit that does the pulling a proxy, inside the VM:

```sh
podman machine ssh 'mkdir -p ~/.config/systemd/user/podman.service.d && \
  printf "[Service]\nEnvironment=HTTP_PROXY=http://host.containers.internal:6152\nEnvironment=HTTPS_PROXY=http://host.containers.internal:6152\nEnvironment=NO_PROXY=localhost,127.0.0.1,host.containers.internal\n" \
  > ~/.config/systemd/user/podman.service.d/proxy.conf && \
  systemctl --user daemon-reload && systemctl --user restart podman'
```

The **user** unit is the one that matters: the macOS client talks to
`podman.service` in the VM's user session, and a drop-in on the system unit changes
nothing. `systemctl --user restart podman` leaves running containers alone;
`podman machine restart` does not.

**Neither this nor the sizing below is applied as of 2026-10-08.** The M2 image work
needed both, and they were reverted afterwards at your request — the drop-in is
gone, the machine is back to its shipped **5 CPUs / 2 GiB**, and the images and
build layers that job produced were deleted. So: *pulling anything, or building an
image with a real dependency tree, is not currently possible on this machine.*
Apply both first when you next need to. Nothing in this plan depends on being able
to: images are built and smoke-tested in CI, and podman is the local path only.

Sizing, when a local build is needed (2 GiB is too small for a real dependency
tree):

```sh
podman machine stop
podman machine set --cpus 8 --memory 12288
podman machine start
# and back again when finished:
podman machine stop && podman machine set --cpus 5 --memory 2048 && podman machine start
```

A machine restart stops running containers, and any container whose restart policy
is `no` stays down. Check first (`podman inspect -f '{{.HostConfig.RestartPolicy.Name}}'
<name>`), then start them again after.

**CI is not affected by any of this.** GitHub runners have ordinary internet and use
Docker + Buildx, so Dockerfiles stay plain — `# syntax=docker/dockerfile:1`,
BuildKit `RUN --mount=type=secret`, no podman-specific syntax — and podman is the
local verification path only.

Building the backend image locally needs read access to the private prompts
repository, which the build takes as a mounted secret, never a build arg:

```sh
gh auth token > /tmp/prompts_token   # must be able to read lo-tp/learn-anything-prompts
cd ../python/learn-anything-backend
podman build --secret id=prompts_token,src=/tmp/prompts_token -t learn-anything-backend:local .
```

CI takes the same value from the repository secret `PROMPTS_TOKEN`.

## Cluster access

`kubectl` and Terraform use **different identities on purpose**, and the reason is
a tool failure rather than a policy preference: `gke-gcloud-auth-plugin` shells out
to `gcloud config config-helper`, and that crashes (`'Credentials' object has no
attribute 'private_key_id'`) whenever the active gcloud credential is a
service-account key. So:

```sh
export PATH="$PWD/google-cloud-sdk/bin:$PATH"   # gcloud + gke-gcloud-auth-plugin
export KUBECONFIG=$PWD/.kubeconfig-gke          # generated, gitignored
gcloud container clusters get-credentials learn-anything --region=asia-east2
```

That uses the logged-in **human** (project owner), which is correct for
interactive cluster work and does not move Terraform, whose credentials the Makefile
pins to `terraform-local`. Never run `gcloud auth application-default login`: it
would repoint Terraform at the human identity.

The GKE **control-plane endpoint is reachable directly** from this network — unlike
`container.googleapis.com`, which black-holes. Going through the proxy works too,
so either is fine; do not conclude from a hung `container.googleapis.com` call that
the cluster is unreachable.

An **idle Autopilot cluster has no nodes**: `kubectl get nodes` returning `No
resources found` is the expected state, not a failure. Nodes appear when a
workload schedules, and disappear again. The managed namespaces
(`gke-gmp-system`, `gke-managed-cim`, …) exist without any node in sight.

A **pipeline uses the third identity**: `deploy-ci`, through Workload Identity
Federation, with no gcloud login and no stored key (`scripts/ci-kubeconfig.sh`).
It reads ADC, which is a service-account credential there — the same situation that
makes `gke-gcloud-auth-plugin` crash on the laptop, and the plugin's
`--use_application_default_credentials=true` is what avoids it *when the plugin
exists*. On GitHub runners it does not: gcloud's component manager is disabled and
the plugin's apt package is in no configured repository, so the script writes a
token-form kubeconfig instead (the plugin's only job is to mint that token, and a
deploy is shorter than the credential that authorizes it). The script prints which
form it wrote.

## Container images

Each app's image is built in its own repository and smoke-tested there, then pinned
here by digest: an image that never answered a request never gets a tag, because the
workflows publish **after** the smoke step, not before. A smoke step is the image's
contract written as a step — run the artifact, assert its first route (`/health`, the
auth redirect to `/en/login`, `/api/compile`). It is worth having on the failure it
catches rather than the one it confirms: on this project it found a production
`npm ci` killed by a devDependency's `prepare` hook, and a working directory the app
user could not write to (`COPY --chown` reaches copied paths, not the directory
`WORKDIR` made). Images use a **numeric** `USER`: `runAsNonRoot` is checked
numerically, so `USER app` fails the pod with `CreateContainerConfigError`. If a
service writes at runtime, its working directory must be writable by that uid.

When pinning, the overlay's `images:` entry must name the image **as base declares
it** — the fully-qualified registry path, not the short name. A short name matches
nothing, kustomize leaves the base `:placeholder` in place, `kubectl apply` reports
`unchanged`, and a deploy that changed nothing looks like a deploy that changed
nothing because it was already right.

## Terraform operation

An interrupted `terraform apply` on this root is recoverable but not silently:
GKE finishes creating the cluster regardless, so the cluster ends up real and
outside state, and the killed process leaves a **stale lock** in the state bucket.
The recovery is `terraform force-unlock <lock-id>` (the ID is in the error text),
then `terraform import` the cluster, then apply — never let a second apply create a
second cluster.

## Deploys

A deploy is an order, not a command: migrations first, then the workloads, then
the rollout. `make deploy` (which is `scripts/deploy.sh`) does that, and the point
of it is that a failed migration stops the deploy with the Job's log printed and
nothing else touched, so what was serving keeps serving. `kubectl apply -k` on its
own skips the gate; use it only for changes that cannot touch the schema.

- **What production runs is written in `manifests/overlays/prod/kustomization.yaml`
  under `images:`** — a digest, with the tag in a comment beside it so a human can
  find the build. That block is the record, and `git diff` of it is the approval.
  CI updates it with `kustomize edit set image`; nothing passes an image on the
  command line, which is why the Job that migrates and the Deployment that serves
  cannot drift apart.
- **Image contracts** (they are enforced by the cluster, so a Dockerfile that
  ignores them fails at pod start rather than at review): a **numeric `USER`** —
  `runAsNonRoot: true` is verified numerically and a named user becomes
  `CreateContainerConfigError`; the uid is spelled once, in the image, never
  again in a manifest; linux/amd64; and a dependency-free readiness route where one
  exists.
- **Migration Jobs are named after what they run** (`migrate-<image digest>-<job
  template hash>`), because a Job's pod template is immutable. A completed one is
  skipped, not re-run; a failed one blocks the deploy until there is a new image
  or a fixed migration.
- **Convergence is checkable**: `kubectl diff` against
  `kubectl kustomize manifests/overlays/prod` should be empty. A non-empty diff is
  either an unapplied change or something edited in the cluster, and both are
  facts worth having before the next deploy.
- **CI runs the apply; Terraform still does not leave the laptop.**
  `.github/workflows/deploy.yml` (push to `main` touching `manifests/` or
  `scripts/`, or manual) renders the Secret objects and runs `scripts/deploy.sh`,
  then fails if `kubectl diff` against the rendered overlay is not empty. Its
  authority is the merge; the job only carries it. `.github/workflows/pin-image.yml`
  is the other half: it reads the registry, and when a newer smoke-passed image
  exists it opens a pull request against one reused branch (`pin/images`) instead of
  applying anything. Merging in the UI matters — a merge performed with the job's
  own `GITHUB_TOKEN` does not re-trigger workflows, and the pin→deploy handoff
  depends on that distinction.
- **Secret values live in Secret Manager, never here.** `make secrets` renders them
  into the cluster Secrets the workloads read (`backend-env`, `sandbox-env`,
  `database-env`) and tells you, out loud, when an entry still holds a placeholder
  — which `openai-api-key` does until M8.
- **A CI workflow's Workload Identity provider is addressed by project *number*:**
  `projects/358071090957/locations/global/workloadIdentityPools/…`. With the project
  *id* in that path, STS answers `invalid_target` and claims the provider may not
  exist. Copy it from `terraform output workload_identity_provider_names` rather
  than writing it out — that path cost one failed pipeline run to learn.

## Public surface

Three hostnames, one address, one certificate. The address is reserved by *name*
(`learn-anything-ingress-ip`) so the DNS rows can be typed before the balancer
exists and survive every later apply; the Ingress refers to it by that name. The
host list lives in Terraform (`variables.tf`) and the Ingress carries a copy —
`make dns-check` compares Terraform, the live Ingress and certificate, what the
registrar answers, and what the certificate's SANs actually contain, and exits
non-zero on a disagreement. Run it before concluding that an unreachable hostname
is a code problem.

Things this cluster does that the manifests do not show:

- **The load balancer's health check comes from the workload's readiness probe**,
  so the probe is judged twice — by the kubelet and by the URL map. Pick a path
  that answers 200 with nothing behind it. `BackendConfig` health checks were
  tried here and changed nothing that was generated.
- **HTTP→HTTPS is a `FrontendConfig` with `redirectToHttps`.** The
  `force-ssl-redirect` annotation is nginx's, ignored here; `spec.tls` without a
  `secretName` is a sync error (`secret "" does not exist`), not a free
  certificate.
- **A woken tier returns 502 for a minute or two after its pod is Ready** — the
  NEG attaches late. That is not a broken deploy; check the
  `service/<name>` events for `Attach 1 network endpoint(s)`.
- **An unprogrammed Ingress with an empty ADDRESS is usually a missing dependency
  in the events**, not a slow LB: the first one waited on the NEG for
  `kube-system/default-http-backend`.
- **All three tiers run at one replica by decision, not as a stopgap**
  (`overlays/prod/replica-floor.yaml`; ADR 0001's amendment). Nothing on this
  platform wakes an idle tier for browser traffic quickly enough to be usable —
  zero-to-browser measured ~4.5 minutes — and the queueing alternatives cost
  control-plane pods at the same per-pod floor they are trying to avoid. Zero
  replicas there is not a saving; it is a 502.
- **Staging has no public surface and no records.** One address = one forwarding
  rule, so a second environment would be a second address and a second monthly
  line; Terraform marks those hosts `dns_records_deferred` rather than leaving
  them unspoken.

## Datastore

The backend relies on a PostgreSQL database, run in-cluster as a StatefulSet with
a persistent disk ([ADR 0002](./docs/adr/0002-postgres-in-cluster.md)), backed up
by a nightly `pg_dump` to object storage. Connection settings reach the backend as
environment variables / Kubernetes Secrets, in the plain `postgresql://…` form the
app rewrites to its own driver. The backend keeps its own migrations as the source
of truth for schema, and a migration Job gates every rollout. Infra owns the
server, the volume, the credentials and the dumps — not tables.

Reaching it, in the two ways that are actually useful:

```sh
# inside the cluster (the postgres image ships psql; no port-forward needed)
kubectl -n learn-anything exec learn-anything-db-0 -- psql -U learn -d learn_anything

# from the laptop, for `alembic`: the password is in the Secret the deploy renders,
# which comes from Secret Manager (`db-password`) via `make secrets`
kubectl -n learn-anything port-forward svc/learn-anything-db 5433:5432
# DATABASE_URL=postgresql+psycopg://learn:<password>@127.0.0.1:5433/learn_anything
```

Two failure modes of this setup look like something they are not, and both were
met:

- **A `volumeClaimTemplate` that no container mounts is not persistence.** The
  PVC says `Bound`, the PV looks healthy, and the data is on the container
  filesystem, so it dies with the pod. `df -h /var/lib/postgresql/data` reporting
  the node's disk rather than the volume's 5 Gi is the one-command check.
- **A fresh volume is not a valid PGDATA.** The filesystem the CSI driver formats
  contains `lost+found`, and `initdb` refuses to run in a non-empty directory.
  The data directory is a subdirectory of the mount (`PGDATA=…/data/pgdata`).

Workload Identity for a **GKE** pool binds with
`serviceAccount:<project_id>.svc.id.goog[<namespace>/<ksa>]` — not the
`principal://…/ksa/…` form, which this cluster's IAM rejects, and not the
`principalSet://…/attribute.repository/…` form that is correct for the GitHub OIDC
providers in `gcp/ci_identity.tf`. Three syntaxes, two of which look interchangeable.

The dumps go to `gs://learn-anything-pgdump` (the name is
`terraform output pgdump_bucket`), and the backup service account holds
`roles/storage.objectCreator` only: it can write a dump and cannot read the
bucket back. Reading and restoring are done with a human identity.

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
