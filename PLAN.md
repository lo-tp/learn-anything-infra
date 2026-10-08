# Plan: deploy Learn Anything on GCP with Terraform + Kubernetes

The ordered path from "four repos, one of them empty" to "Learn Anything runs at
`learn.lotp.xyz`, described entirely in this repo, and Render is gone."

Each milestone ends on a **completion criterion** — the condition that says it is
done. Do the milestones in order; each one's criterion is the next one's
foundation. The *why* behind each load-bearing choice lives in
[`docs/adr/`](./docs/adr/), not here. The words used here are defined in
[`CONTEXT.md`](./CONTEXT.md).

## Inputs that hold this shape

- **GCP, `asia-east2`.** The binding constraint is a dated one: **the $300 trial
  credit expires 2027-01-06** (billing account `01C0D4-4C9481-8E0DC4`), which
  implies a trial start of 2026-10-08 and leaves **91 days from 2026-10-07**.
  That makes the hard ceiling **$3.30/day for the platform** — not the earlier
  ~$3.33 estimate. The design target in the first draft of this plan was **platform
  ≤ $35/month**; it was retired on 2026-10-08 when option (D) was chosen (see M3's
  option table and ADR 0001's amendment): three application tiers pinned at one
  replica is **~$50/month of pods at Autopilot's per-pod floor**, before any
  load-balancer line, and no amount of tuning requests changes that, because the
  billing floor (0.25 vCPU / 1 GiB per pod) is above what the containers ask for.
  The number now held to is the credit's — **stay under $3.30/day through
  2027-01-06** — with the Terraform budget alert set at $70/month as a tripwire
  for *unusual* spend, not as a target (an alert that fires every month is
  noise). Read and recalibrate it at the M10 checkpoints from billed figures.
- **The credit belongs to the billing account, not to this project — and you have
  confirmed this project is the only thing drawing on it.** M1 still creates two
  budgets, but their jobs differ now: the one filtered to this project measures
  what the platform costs, and the unfiltered one is a **canary** — it should stay
  silent, and if it fires, something unknown is spending your January.
- **Inference is outside that budget.** You said the LLM/API spend is not counted
  against the 300-credit figure, so no milestone here caps it — but M8 measures it
  anyway, because it is the largest real cost and the platform budget says nothing
  about it.
- **Domain `lotp.xyz`, registered and DNS-hosted at Namecheap — and it stays
  there.** Ours: `learn.`, `api.`, `sandbox.` and the staging variants, entered by
  hand in Namecheap because their API allowlists single IPs and won't take a range
  ([ADR 0004](./docs/adr/0004-dns-stays-at-namecheap.md)). `blog.lotp.xyz` →
  `lo-tp.github.io` is a **foreign record**: never touched, and untouched by this
  plan. The apex and `www.` have no records today; leave them that way.
- **Terraform drives everything; `gcloud` creates nothing.** The rule, and the one
   thing it doesn't cover (the credential helper `kubectl` needs), is in
   [`AGENTS.md`](./AGENTS.md). Two things stay outside Terraform's reach and both
   are one-time: the free-trial signup (no API for it) and the credentials — see
   Step 0.
- **Nothing is deployed yet except the Render blueprint in the backend repo**, and
  that is what we are leaving.

## Step 0 — the three things only you can do

1. ~~Create the GitHub repo `lo-tp/learn-anything-infra`, add it as `origin`,
   push.~~ **Done** — `github.com/lo-tp/learn-anything-infra` (private), `origin`
   set, `main` pushed. No pipeline in this plan can run before this.
2. ~~Sign up for the trial, create the project, find the billing account ID.~~
   **Done except one number.** Project `learn-anything-510905` (number
   `358071090957`); billing account **`01C0D4-4C9481-8E0DC4`** ("My Billing
   Account", open), read with `gcloud billing accounts list` once you were signed
   in. **Still yours: the trial expiry date.** The Billing API does not expose
   credit expiry — `billing accounts describe` returns no create time and no
   credit fields — so that one value only exists on the Credits page in the
   console. Without it the 90-day limit in M10 has no start.
3. ~~Create the service account Terraform will act as, and grant it its roles by
   hand.~~ **Done as far as a human can.** `terraform-local` was created, its key
   moved out of the repo (`~/.config/gcp/learn-anything-510905.json`, mode 600),
   and the one bootstrap grant a human identity alone can make is attached and
   verified:

   ```
   gcloud projects add-iam-policy-binding learn-anything-510905 \
     --member serviceAccount:terraform-local@learn-anything-510905.iam.gserviceaccount.com \
     --role roles/owner
   ```

   The eleven granular bindings below are now **mine, in Terraform**, in M1 —
   role bindings are configuration, and a `gcloud` grant would leave them invisible
   to `terraform plan` and untraceable to anyone reading this repo. `owner` gets
   removed in the same change. The two billing-account roles stay a question:
   a trial account may refuse a service account there, and if it does the budgets
   move to hand-applied, the way ADR 0004 handles DNS.
   roles/container.admin                      GKE
   roles/compute.networkAdmin                 the VPC and subnetwork
   roles/artifactregistry.admin               image repository
   roles/storage.admin                        Terraform state and pg_dump buckets
   roles/secretmanager.admin                  secrets (M7)
   roles/serviceusage.serviceUsageAdmin       letting Terraform enable APIs
   roles/iam.serviceAccountAdmin              creating the CI and node identities
   roles/iam.serviceAccountUser               granting those to workloads
   roles/resourcemanager.projectIamAdmin      GKE grants roles to its own agents

   # on the billing account, not the project — may be refused on a trial account;
   # if it is, the budgets move to hand-applied like DNS (ADR 0004)
   roles/billing.viewer
   roles/billing.budgetsWriter
   ```

   ~~Give the tools something to authenticate with.~~ **Done** — the key was
   downloaded into this repo (a secret one `git add .` away from git history) and
   is now `~/.config/gcp/learn-anything-510905.json`, mode `600`, with a
   `.gitignore` pattern to catch a re-download. The credential is verified: it
   mints a token and reaches the GKE API through the proxy. CI's Workload
   Identity Federation comes later from Terraform, not from you.

   Which identity Terraform acts as: **settled on (A)** — the `terraform-local`
   key. Narrow, and it matches the shape CI will use (a workload identity, not a
   human), so one authority model covers laptop and pipeline. The cost of that
   choice is the one bootstrap grant: `roles/owner` on the project, attached by
   hand, then dropped once the granular bindings below are live.

Tooling, checked now that the SDK is installed: Google Cloud CLI **588.0.0** at
`google-cloud-sdk/` in this working tree — 378 MB, untracked, now gitignored, and
better moved out of the repo. **No account is signed in to it.**
`gke-gcloud-auth-plugin` is **not** part of this install (it's a separate
component: `gcloud components install gke-gcloud-auth-plugin`), and `kubectl`
1.27 is several minor versions behind a cluster GKE would create today — both
belong to M3, not to M1. `docker-credential-gcloud` *is* present, which is what
makes local image pushes work in M2; note that Docker Desktop needs its own proxy
setting, separate from the shell's.

Terraform and `kubectl` must go through the local HTTP proxy; see *Network* in
[`AGENTS.md`](./AGENTS.md), and `make tf-plan` / `make tf-apply` set it for you.

**Status: complete.** Every item above is done and verified, and the credit's
expiry date (2027-01-06) is recorded in *Inputs* with the window it implies.
`bootstrap/` has been applied: `learn-anything-tfstate` exists in `ASIA-EAST2`, and reading it back
from the API confirms `versioning_enabled: true`, `public_access_prevention:
enforced`, `uniform_bucket_level_access: true`. Its outputs print the `backend
"gcs"` block that `gcp/` will use.

Two APIs — `cloudbilling` and `cloudresourcemanager` — were enabled during this
bootstrap because the bootstrap could not read or grant anything without them.
That is **not drift**: `google_project_service` in M1 declares them too, and
declaring an already-enabled service is a no-op.

**Done when:** the expiry date is recorded here. Everything else in this step is
verifiable in the outputs above.

## M1 — Terraform foundation

**M1 begins by importing the project**, because it was created by hand in Step 0:
`terraform import google_project.main learn-anything-510905`. Until that is done
Terraform cannot attach billing or set project settings, and the project sits
outside the one place everything else is described.

Two roots, decided by where state lives: **`bootstrap/`** creates one thing — the
versioned GCS bucket that holds Terraform state — and keeps its own local state,
because a backend cannot create itself. Everything after that lives in **`gcp/`**
with remote state in that bucket: every API the project needs
(`google_project_service`: `container`, `secretmanager`, `artifactregistry`,
`compute`, `iam`, `cloudresourcemanager`), the VPC + subnetwork, the GKE
**Autopilot** cluster in the `asia-east2` **region**, Artifact Registry with a tag
cleanup policy, the `pg_dump` bucket (separate from the state bucket on purpose),
Secret Manager entries, the CI identity with Workload Identity Federation, and
**budget alerts that include credits**. A monthly budget (currently $70 — a
tripwire above the chosen topology's floor, see the constraint above and
`var.monthly_platform_budget_usd`), alerting at 50/75/100% with `credit_types_treatment =
INCLUDE_ALL_CREDITS`: while the trial credit hides the cost on the bill, the
budget still measures real consumption, which is the whole point of the
90-day constraint. Terraform creates all of it — with one deliberate exception,
and it isn't here (ADR 0004).

**Done when:** `terraform plan` is empty on a re-run; `terraform state list`
shows the cluster, registry, bucket, budgets and service account; the cluster's
control plane answers `kubectl get --raw /readyz` with `ok`.

~~`kubectl get nodes` reports a Ready node~~ — that check was wrong, and it was
worth being wrong: an **Autopilot cluster has no nodes while nothing is
scheduled**, which is exactly the property ADR 0001 pays for. Verified on the
real cluster: `No resources found`, with only the managed namespaces
(`gke-gmp-system`, `gke-managed-cim`, …) present.

**Status: applied.** `terraform plan` re-runs to *No changes*, and state holds the
project, 14 APIs, VPC + subnetwork, the Autopilot cluster (`learn-anything`,
`asia-east2`, server `v1.35.8-gke.1225000`), Artifact Registry with the cleanup
policy enforced, both buckets, 7 Secret Manager entries, the CI identity with three
WIF providers, both budgets and the billing-account grant. `roles/owner` is gone
from `terraform-local`, replaced by the granular set in `iam.tf`.

Applying it took five attempts, and each failure is now a comment in the file that
caused it: API-enablement races (403 "API has not been used in project…"), OIDC
providers requiring `attribute_mapping`, `roles/billing.budgetsWriter` not being
grantable on a billing account, a missing `roles/iam.workloadIdentityPoolAdmin`
that cannot self-heal because the permission is needed at refresh time, and an
Artifact Registry cleanup policy whose `action` must be `KEEP` — the API's own error
for the wrong value is just "invalid repository" plus the whole request body.
One apply was interrupted mid-cluster-creation; GKE finished the cluster anyway,
which left a real cluster outside state and a stale GCS state lock. Rejoined with
`terraform force-unlock` then `terraform import`, rather than letting Terraform
build a second cluster.

Two environment facts that only showing up on the real cluster could teach: the
GKE **control-plane endpoint is reachable directly** from this network (unlike
`container.googleapis.com`, which black-holes), and `gke-gcloud-auth-plugin`
crashes when the active gcloud credential is a service-account key — so `kubectl`
runs as the human identity while Terraform keeps the service principal.

## M2 — Images (this is where the work actually is)

No repo has a `Dockerfile`. Add one, plus a build workflow, to each app repo;
each pushes to Artifact Registry and the infra repo consumes digests.

- **Backend**: Python 3.13, `uv sync --frozen --no-dev`, and the **private
  `prompts/` submodule baked into the image at build time** using `PROMPTS_TOKEN`
  as a build secret. Start with `uvicorn main:app --host 0.0.0.0 --port $PORT`.
  Migrations move out of the build (M5).
- **Frontend**: `next build` then `next start`. `NEXT_PUBLIC_*` values are
  **inlined at build time**, so the image is environment-specific: CI passes
  `NEXT_PUBLIC_BACKEND_URL` / `NEXT_PUBLIC_SANDBOX_ORIGIN` as build args per
  environment. A staging image is not the prod image.
- **Sandbox**: Node runtime, `node_modules` and `esbuild`/`typescript` present at
  runtime, and the **`out/slides/harness.js` + `out/slides/vendor/*` artifacts
  baked into the image** (they are gitignored but read from disk on every
  request). The container needs a writable working directory: `/api/compile`
  writes temp files into it.
- Pushing needs no `gcloud`: CI trades its GitHub OIDC token for a federated
  workload-identity access token and `docker login`s to Artifact Registry with it.

**Done when:** three images sit in Artifact Registry, built by CI and not by hand,
and each one starts under a container runtime and answers its own first route
(`/health` for the backend, `/` for the frontend, `/slides/...` or
`/api/compile` for the sandbox).

**Status: all three images exist, each verified by its own workflow, and all three
are pinned in `overlays/prod` by digest.** The backend has a `Dockerfile`, a
`.dockerignore` and `build-image.yml`, and CI builds and pushes it: `main` → an
image tagged `sha-<commit>` in Artifact Registry, and production is pinned to one of
those digests (`dd32533a…`, from `fdb0b377`). Locally it was verified earlier: 48 s
warm build, starts as uid 10001, `/health` answers `{"status":"ok"}`, `prompts/` is
baked in, 17 routes, 495 MB.

For the two Node services, verification moved to CI deliberately: building an amd64
image of those dependency trees on this laptop means qemu plus a proxied `npm ci`,
which took longer than the pipeline it was meant to check. So the gate's second half
became a **smoke step** in each workflow — run the artifact, assert its first route.
That step paid for itself twice, in two bugs nothing else found:

- **`npm ci --omit=dev` ran the package's `prepare` hook, which calls `husky` — a
  devDependency that stage deliberately does not install.** Exit 127, on a command
  nobody asked for. The fix is `--ignore-scripts`; esbuild's postinstall is the one
  hook worth reasoning about, and the answer is that its binary arrives as a
  platform-specific optional dependency, which the smoke step then proves by
  compiling a component for real.
- **The working directory was not writable by the app user.** `COPY --chown` reaches
  the copied paths, not the directory `WORKDIR /app` created, so the sandbox
  started, routed `/api/compile`, and failed writing its own gate fixture:
  `EACCES: permission denied, open '/app/compile-gate-….cjs'`. A container that
  writes at runtime needs its *directory* writable, which is a different claim from
  "its files are owned by the app user".

The workflow order is now build → smoke → **publish**, so an artifact that never
answered a request never gets a tag; the one that had (`sha-d16da99…`, the sandbox
build with the unwritable directory) was deleted from the registry.

The first CI runs failed twice, in ways no local build could have taught:

- **The Workload Identity provider path is `projects/<PROJECT_NUMBER>/…`, not
  `projects/<PROJECT_ID>/…`.** STS answered `invalid_target` and a message saying
  the provider might not exist — it was present and active. The authoritative copy
  of that path is now `terraform output workload_identity_provider_names`, so the
  frontend and sandbox workflows can be written correctly the first time.
- **`docker/login-action` received an empty password** from
  `google-github-actions/auth`'s `access_token` output and failed with "Password
  required". The job mints the token with `gcloud auth print-access-token` from the
  credential file the auth step exports; if that is ever empty again, the error
  names the credential rather than a missing input.

Two things worth keeping straight, because both were nearly got wrong:

- **The pipeline builds images, not the laptop.** For a while production pointed at
  a hand-built amd64 image because CI was not working yet — that was a temporary
  state, it is over, and the three laptop-built tags were deleted from the registry
  so that production cannot point at something no pipeline produced. Local builds
  exist to *verify a Dockerfile*, which is a different thing (and the amd64
  requirement is a fact about the cluster, not a preference: `podman build
  --platform linux/amd64`).
- **`PROMPTS_TOKEN` is set** on `lo-tp/learn-anything-backend` (a read token for
  `lo-tp/learn-anything-prompts`, supplied by you). Without it the job stops at the
  submodule step and says so — which is the behaviour that made the missing secret
  obvious rather than mysterious.

The backend's build does not clone the private `prompts/` submodule itself — that
would need `git` in the image, i.e. an `apt` step, which on this network was most
of the build time. CI initialises the submodule from the pinned commit, the local
build uses the checked-out submodule, and the Dockerfile fails with a named reason
if it is missing.

## M3 — Workloads as Kustomize base + overlays

`base/` plus `overlays/prod` and `overlays/staging`. Deployments, Services,
HPAs, resource requests/limits, probes.

- **Backend**: `replicas: 1`, `strategy: Recreate`, never scaled to zero
  ([ADR 0003](./docs/adr/0003-single-replica-backend.md)). Probes on `GET
  /health` — which is deliberately dependency-free, so a slow database is not
  interpreted as a dead pod.
- **Frontend and Sandbox**: `HPA minReplicas: 0`, so an unused app is nearly
  free. The first visitor pays a cold start; that trade is part of
  [ADR 0001](./docs/adr/0001-gke-autopilot-with-scale-to-zero.md).
- Tight `requests` on every container, because Autopilot bills on requests.

**Done when:** `kubectl kustomize overlays/prod` renders, applies cleanly, and
`kubectl get pods` shows the backend Ready while the other two sit at zero.

**Status: written and validated; the production overlay is now applied (see M5,**
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
by the invoice in M10):

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

## M4 — Postgres in-cluster

StatefulSet + PVC + headless Service, its credential generated by Terraform into
Secret Manager, and a nightly `pg_dump` CronJob writing to the GCS bucket
([ADR 0002](./docs/adr/0002-postgres-in-cluster.md)). `postgres:17`, matching
the dev compose file. `DATABASE_URL` handed to the backend in the plain
`postgresql://…` form — the app rewrites the driver scheme itself.

**Done when:** `alembic upgrade head` succeeds against it, and deleting the
database pod leaves the data intact when it comes back.

**Status: applied, and the gate passes (2026-10-07).** `postgres:17.11` (the
plan said `postgres:17`; a mutable tag under a database is not the same thing as
a version), 5 Gi on `dynamic-rwo`, one headless Service, one credential generated
by `random_password` into Secret Manager as `db-password`, and the nightly
CronJob. Gate evidence:

- `alembic upgrade head` over a port-forward: `alembic current` reports
  `c3d4e5f6a7b8 (head)` and 10 tables exist.
- A row written before `kubectl delete pod learn-anything-db-0` is readable after
  the replacement pod starts, the PVC and PV keep their identities, and the new
  pod's log says `database system was shut down … ready to accept connections`
  instead of running initdb.
- One manual run of the CronJob (`kubectl create job --from=cronjob/db-backup`)
  uploaded `learn_anything-<timestamp>.sql.gz` (27.5 KB) to
  `gs://learn-anything-pgdump`. The CronJob itself is left in place for its
  17:30 UTC schedule; the manual Jobs were deleted.
- `kubectl kustomize` renders 15 objects for each overlay; staging's StatefulSet
  comes out at `replicas: 0` with the CronJob `suspend: true`, and the prod set
  passes `kubectl apply --dry-run=server` with no errors. The *whole* overlay is
  applied now (M3 closed); what the data tier was waiting for was images and the
  other Secrets, and both exist.
- **`make secrets` did not write.** It built each Secret with `create
  --dry-run=client -o yaml` and piped it into `kubectl apply --dry-run=server`: a
  validation that never persisted anything. `backend-env` and `database-env` existed
  only because an earlier version of the script had created them, so the gap was
  invisible until a *new* Secret (`frontend-env`) came out "created (server dry
  run)" and was not there afterwards. It applies now, and `CHECK_ONLY=1` is the
  validate-without-writing path. Rendering a Secret is not the end of a rotation
  either: a running container keeps the environment it started with, so a rotated
  value reaches a pod only when that pod is replaced.

Things it took to get right, each of which would have been worse to meet later:

- **A `volumeClaimTemplate` that is not mounted is not persistence.** The first
  version declared the PVC and never put a `volumeMounts` entry in the container,
  so Postgres wrote to the container filesystem: the PVC sat `Bound`, the PV
  looked healthy, and deleting the pod deleted the schema. `df -h
  /var/lib/postgresql/data` showing the node's 95 GB instead of the volume's 5 GB
  is a one-command test for whether the mount is real; that is what the comment in
  `manifests/base/database.yaml` records.
- **`initdb` refuses a fresh volume used as PGDATA**: the filesystem the CSI
  driver formats contains `lost+found`, and initdb says *"directory exists but is
  not empty … perhaps due to it being a mount point"*. Fix is a subdirectory —
  `PGDATA=/var/lib/postgresql/data/pgdata` — which is also why the mountPath is
  one level above it.
- **Workload Identity member syntax for a GKE pool is not the generic
  Workload Identity Federation syntax.** `principal://…/ksa/<ns>/<ksa>` was
  rejected twice ("Invalid principal member", then "of an unknown type"); what
  this cluster's IAM accepts is
  `serviceAccount:<project_id>.svc.id.goog[<namespace>/<ksa>]`, matching the GKE
  docs. `gcp/ci_identity.tf` (GitHub OIDC) legitimately uses the other form, so
  copying between the two is a trap.
- **The backup job's grant is write-only on purpose**, and the job found that out
  itself: its last line used to be `gcloud storage ls`, which failed with
  `storage.objects.list denied` because the service account holds
  `roles/storage.objectCreator` and nothing more. The read was removed rather than
  the grant widened; the job's log prints the object URI and how to restore it.
- **`gcloud` in an unprivileged container needs a writable config dir**
  (`CLOUDSDK_CONFIG`), or it dies talking about `/​.config/gcloud` permissions
  before it ever reads a credential.
- **The backend's `DATABASE_URL` is a psycopg3 URL, not an asyncpg one**
  (`learn-anything-backend/db/models.py:45` rewrites a driver-less
  `postgresql://` URL); an asyncpg URL would have survived that rewrite and then
  failed at connect time.

Not yet done, and it belongs on the list: **the dump has never been restored.**
Writing an archive is not the same as having a recovery, and the first time this
archive is read should not be the time it is needed. M9 has the restore drill.

`scripts/render-secrets.sh` (and `make secrets`) is the bridge from Secret Manager
to cluster Secret. It is deliberately dumb; M7 moved *who runs it* into the
pipeline rather than replacing it, because the mapping from Secret Manager entries
to environment variable names is a contract the apps compile against and Terraform
has no business owning. It refuses to render an empty required value, and says so
when a value is still a placeholder.

## M5 — Migrations as a gate

A `Job` that runs `alembic upgrade head`, applied before the Deployment rolls,
so a migration failure blocks the rollout instead of restarting a pod that cannot
reach its schema.

**Done when:** a deliberately broken migration revision makes the deploy fail with
a visible Job log, and the previous Deployment is left serving.

**Status: applied, and the gate works in both directions (2026-10-07).**
Production is running: one backend pod (image digest `dd32533a…`, built by CI from
`fdb0b377`) serving `/health` through its own readiness probe, next to the
database. The two frontend tiers are at zero (no images yet — see below).

The mechanism is `scripts/deploy.sh` (and `make deploy`), in that order: read the
image the overlay names → run *that* image's `alembic upgrade head` as a Job and
wait → only then `kubectl apply` the overlay and wait for the rollout. The image
comes out of `manifests/overlays/prod/kustomization.yaml` rather than from an
argument, so what gets migrated and what gets deployed cannot disagree.

Gate evidence:

- **Positive**: `migrate-d1e0c6075189-…` completed, then the Deployment rolled
  (`deployment "backend" successfully rolled out`), then `curl` through the
  Service returned `{"status":"ok"}` and the migration log showed the schema at
  head. Re-running the same deploy applied 12 unchanged objects and said so.
- **Negative**: a revision whose `upgrade()` raises was built into an image
  (`local-m5-probe`) and pointed at in the overlay. The deploy stopped at the
  gate with the log naming the file and the line
  (`alembic/versions/zzz_m5_probe_fails.py, line 17 … fails on purpose`), exited
  non-zero, and the live Deployment still pointed at the previous digest with
  `ready=1`. The probe revision was never committed and has been deleted; the
  image stays in the registry as a rejected artifact.
- Converged state is checkable in one command: `kubectl diff` against
  `kubectl kustomize manifests/overlays/prod` is empty.

What the design had to learn about Jobs, which is all in `deploy.sh` comments:

- **A Job's name must change when anything that runs changes** — its pod template
  is immutable. The name is therefore `migrate-<12 hex of image digest>-<6 hex of
  the rendered Job template>`; editing the Job definition alone would otherwise
  make the next deploy die on "field is immutable".
- **Re-applying an unchanged Job is also rejected**, because GKE's own defaults
  (dropping `NET_RAW`) make the stored object differ from the file. So a Job that
  already completed is reported and skipped, and one that already failed is
  reported and stops the deploy: a schema error is not transient, and re-running a
  completed migration buys nothing.
- **The image's `USER` has to be numeric.** `USER app` is a name Kubernetes
  cannot resolve, so `runAsNonRoot: true` — the contract the base manifests
  assert — fails as `CreateContainerConfigError: image has non-numeric user (app)`.
  The backend now uses `USER 10001` (backend repo `d93da1a`). The instruction for
  the two images M2 has not written yet: numeric uid, and no `runAsUser` in the
  manifests, so the uid is spelled once.
- **A `:placeholder` image is now visibly wrong, not merely unbuilt.** One aborted
  deploy left a migration Job pulling `learn-anything-backend:placeholder` into
  ImagePullBackOff, which is the correct symptom for "the overlay never said what
  to run". Worth remembering when something looks like a registry problem.

Two things that are *not* finished inside this milestone, one of which moved while
this was being written:

- **The image production runs is the pipeline's.** `PROMPTS_TOKEN` is set, CI builds
  and pushes `sha-<commit>`, and the production digest is one of those; the three
  laptop-built tags were deleted so no future deploy can reach for them. The gate
  itself ran against that CI image: `migrate-dd32533ac7d8-…` completed, the
  Deployment rolled onto it, `/health` answered, and `alembic_version` still reads
  `c3d4e5f6a7b8`.
- **`OPENAI_API_KEY` in Secret Manager is still a placeholder**
  (`REPLACE_ME-openai-api-key-not-yet-supplied`). The pod starts because the
  variable exists; the first real LLM call would not work. `make secrets` prints
  that fact rather than swallowing it. M8 needs the real key.
- Frontend and sandbox images do not exist (M2 continues), so their Deployments are
  patched to zero replicas in the production overlay (`asleep.yaml`) rather than
  left to schedule pods that cannot pull. Their placeholder HPAs were removed: an
  autoscaler that insists on at least one replica contradicts the scale-from-zero
  choice in ADR 0001, and a KEDA ScaledObject expects to find the Deployment at
  zero.

## M6 — One public surface, three hostnames, real certificates

One global Application Load Balancer, one static IP, one Google-managed
certificate covering `learn.`/`api.`/`sandbox.lotp.xyz` (plus the staging hosts).
Ingress routes by Host header. The sandbox's `/api/compile` is **never routed**:
it stays a ClusterIP Service the backend calls directly
([CONTEXT.md → public surface](./CONTEXT.md)).

Then the records. **The zone never moves and the nameservers are never changed**:
`blog.lotp.xyz` and everything else you already have stay exactly where they are.
The set of records we need lives in this repo as a variable, and
`terraform output dns_records` prints it as rows to type into Namecheap —
A records for `learn.`, `api.`, `sandbox.` and the staging hosts, all to the one
static IP. Google issues the certificate only once those records resolve, so this
is a gate, not a formality.

**Done when:** `curl -I https://` works on all three hosts with a valid cert, the
sign-in cookie works from `learn.` to `api.` (same-site, cross-origin), the
records typed into Namecheap match `terraform output dns_records` line for line,
and `https://blog.lotp.xyz` still serves from GitHub Pages — unchanged because
nothing near it was touched.

**Status: done, and every clause of that gate was executed (2026-10-08, ~00:45
local).** Three A records at TTL 300 point at the reserved address; the managed
certificate is `Active` and its SANs cover all three names; `make dns-check`
exits 0. Through the public surface: `http://api.lotp.xyz/health` → 301 → `https`
→ 200; `learn.` sends an anonymous visitor to `/en/login?next=%2F` and gives a
signed-in one **200 at `/en`** with real UI text; `sandbox./slides/x` is 200 with
`Sec-Fetch-Dest: iframe` and 403 without (that app's own gate, working on the
public host); `sandbox./api/compile` is a URL-map miss, which is the "never
routed" rule holding; `blog.lotp.xyz` is untouched GitHub Pages. The session
crosses surfaces because the backend now writes the cookie for `.lotp.xyz`
(`COOKIE_DOMAIN`), verified end to end: `#HttpOnly_.lotp.xyz` in the jar,
`/auth/me` → the user, signed-in `GET /` → 200.

What it took, none of it visible in a `kubectl get ingress`:

- **Programming the balancer took ~35 minutes, and the reason was in the
  events, not the status.** `Error syncing to GCP: … networkEndpointGroups/
  k8s1-…-kube-system-default-http-backend … was not found`: the controller was
  waiting on the NEG for GKE's own catch-all backend. It fixed itself by creating
  that NEG; `ADDRESS: <empty>` told me nothing.
- **`ingress.kubernetes.io/force-ssl-redirect` is an nginx-ingress spelling; this
  controller ignores it.** The URL map carried no `httpsRedirect` with it in
  place. `spec.tls` without a `secretName` is worse than useless — it produced
  `Error syncing to GCP: secret "" does not exist`. The mechanism that works is a
  **FrontendConfig** with `redirectToHttps.enabled: true`, attached by annotation;
  the redirect then appears on the target HTTP proxy (not in the URL map's path
  matchers, so checking there misleads you).
- **BackendConfig health checks did not change what was built.** GKE generates the
  load balancer's health check for a NEG **from the workload's readiness probe**
  where it can — one backend's check says so in its description — and a default
  connect check otherwise; three BackendConfigs, correctly annotated and present
  before the balancer was created, left the generated checks as they were. They
  are deleted here, and the probes are the honest single definition: the
  frontend's readiness path is `/en/login` rather than `/` (the root is a
  redirect; passing on a 307 proves a socket, not a page), and the sandbox's is
  HTTP on a static page instead of TCP.
- **A woken tier answers 502 for 1–4 minutes after its pod is Ready.** The NEG
  attaches to the backend service after the endpoint exists. Twice observed (a
  rollout, then a scale-up), which is a fact for the scale-from-zero work still
  open: wake latency is not only scheduling, it is the URL map catching up.
- **Waking a third tier can fail outright.** With backend and database resident,
  the frontend pod came back `Insufficient memory` with the cluster autoscaler in
  backoff after 16 failed scale-ups; deleting the pending pod got it scheduled
  onto its own Autopilot node. Two things follow: three tiers awake is not one
  node, and "delete the stuck pod" is the unstick.
- **Staging does not have a public surface, on purpose.** An address holds exactly
  one global forwarding rule, so a second environment is a second address and a
  second forwarding rule — a second monthly line — not another host block on this
  one. Terraform declares those six names but separates *pointed* from *held*
  (`dns_records` vs `dns_records_deferred`), because a record that resolves to an
  address with no rule behind it looks exactly like a broken deploy. Whether
  staging is worth the line is an M9 decision, and by then M10's checkpoints will
  have priced the first one.

**For M10's first checkpoint, the list of SKUs to read in the bill now includes the
public surface**: a global static address in use, and *two* global forwarding rules
(one per target proxy, HTTP and HTTPS) on that one address, plus the data
processed through them. None of that is in the earlier cost notes, and none of it
is a per-pod number, so it will not show up in the requests table this plan has
been watching.

## M7 — Secrets to pods

Terraform owns which secrets exist; CI reads them from Secret Manager and applies
rendered `Secret` objects at deploy time. No always-on sync controller. Required:
`JWT_SECRET` (backend + frontend, one value), `SANDBOX_SERVICE_TOKEN` (backend +
sandbox, one value, both ends fail secure), the DB credential, and
`OPENAI_API_KEY` / `OPENAI_BASE_URL` / `LLM_MODEL`. `PROMPTS_TOKEN` stays
build-time only and never reaches a pod.

**Done when:** no secret value appears in this repo or in any image, and both
shared pairs match across services (an `MISMATCH` here shows up as 401s from
`/slides/{id}` and 401 sign-ins, so verify it in M8).

**Status: done (2026-10-08, ~00:50 local), including the first real CI apply.**

- `.github/workflows/deploy.yml` is the pipeline form of `make deploy`: WIF →
  `deploy-ci` → cluster credentials through application default credentials →
  render the Secret objects → `scripts/deploy.sh` (migrations, workloads, rollout)
  → fail if `kubectl diff` against the rendered overlay is not empty. No secret is
  stored in GitHub; there is no sync controller; the reconcile happens at deploy
  time, by whoever deploys.
  The first green run (54s, on the push that added it) says the parts in its own
  log: `control plane reachable as deploy-ci@learn-anything-510905…`, four Secrets
  `unchanged` with the M8 entries named as skipped, `migration Job
  migrate-4cf283528e5f-4428bd already completed; not re-running it`, three
  deployments `unchanged`, then `no drift` and the three digests it is serving.
  An apply that changed nothing, performed by a pipeline: the right outcome for a
  push that changed no manifest.
- `.github/workflows/pin-image.yml` closes the loop M6 left open: the registry is
  asked what it holds (newest `sha-<commit>` version, which in those repositories
  means built by CI **and smoke-passed**, because publish runs after the smoke
  step), and a newer one becomes a pull request on one reused branch. It applies
  nothing. Merging, in the UI, is what deploys. Its steady-state path is the one
  that has run: authenticate, compare, find the pins current, say so, open nothing.
  **The pull-request path is unexercised** — it needs a newer published image, and
  inventing one to test it would have been a fake pin in the registry. It gets
  tested by the first real one, and the failure mode if it is broken is visible:
  the job says which branch it took.
- Both halves of the Done-when are now commands. `make secrets-check` compares the
  renderer's mapping against `terraform output secret_names` — 6/6 agree. Live
  output of `make secret-hygiene`: every Secret Manager entry absent from all four
  repositories **and from the filesystem of the running images**, and
  `JWT_SECRET` (backend/frontend) and `SANDBOX_SERVICE_TOKEN` (backend/sandbox)
  equal to each other and to Secret Manager, as hashes of what the containers hold.
  The three M8 entries report as empty/placeholder, which is what they are.

What it took, in the order the failures arrived:

- **A pipeline can hold a GKE credential with no gcloud login.** The plugin form
  works — `gke-gcloud-auth-plugin --use_application_default_credentials=true`, the
  *same* flag that sidesteps the `private_key_id` crash AGENTS.md documents, because
  there ADC really is a service-account key. Verified before writing the workflow:
  `deploy-ci` reads the cluster, dry-run-applies the whole prod overlay, and reads
  Secret Manager. The test key was then deleted.
- **GitHub runners have no `gke-gcloud-auth-plugin` and cannot be given one that
  way.** The component manager is disabled in the image's gcloud, and the package it
  names (`google-cloud-cli-gke-gcloud-auth-plugin`) is not in any configured apt
  repository — `Unable to locate package`, twice, in six seconds each. So the
  kubeconfig carries a token: `scripts/ci-kubeconfig.sh` writes either the exec form
  (plugin present, tokens minted on demand) or the token form (an access token
  minted once, which outlives the job that uses it). Both forms are tested here, the
  second by moving the laptop's plugin binary aside.
- **The runner's gcloud has its component manager disabled**, and names the fix
  verbatim: `sudo apt-get install google-cloud-cli-gke-gcloud-auth-plugin`. Three
  pushes to learn, because my first version hid the tool's output.
- **Two YAML traps in workflow files, both rejected before any step ran** — a run
  that fails in 0 seconds with no log at all. An unquoted step name containing
  `Deploy: ` is a mapping inside a mapping; a multi-line commit message inside a
  `run: |` block scalar has lines starting at column 1, which ends the scalar.
  Parse the file (`ruby -ryaml -e …`) before pushing it: GitHub's own report of
  these two mistakes is a failed run with no log and no reason.
- **Roles belong to the service account, not to a repository.** `deploy-ci` already
  held `container.developer` and `secretmanager.secretAccessor` (granted in M1 for
  the deploy step that did not exist yet), so adding this repository to the WIF
  list gave it those powers instantly — and the three image pipelines can now apply
  workloads too. `image_repositories` is renamed `ci_repositories` to stop the
  variable implying a scope the grant does not have.
- **gcloud exits non-zero when a Secret payload is empty**, so `set -e` ended the
  renderer before it could say which kind of empty it was. `OPENAI_BASE_URL` and
  `LLM_MODEL` are now *skipped while empty* rather than rendered as `""`: the
  backend passes an empty base URL to the client, which is a worse failure than an
  unset variable.
- **One key entry on `deploy-ci` refuses to be deleted**: `GET` returns 200, `DELETE`
  and `disable` return `NOT_FOUND`, repeatedly. Its private half is held by nothing
  in this project (grep over the credential locations finds no match), so nothing
  can authenticate with it. Recorded rather than chased; worth one look at the M10
  checkpoint to confirm it is gone.

Deferred to M8 by design: `openai-api-key` still holds its placeholder and
`openai-base-url` / `llm-model` are empty. M7's renderer path for them exists and
is exercised; the values are the human step at the start of M8, after which
`make secret-hygiene` is re-run — the pair checks are the part M8's own
"Done when" depends on.

## M8 — Prove it, then let it use the real LLM

Acceptance runs with `MOCK_LLM=1` first: tables are created at startup,
`DATABASE_URL` is ignored, and no token is spent. That is the cheapest possible
end-to-end test of ingress, TLS, DNS, probes and the sandbox fetch.

Then flip staging to the real endpoint and **measure one complete session**:
tokens and wall-clock per session, written down in this repo. Inference is outside
the platform budget by your instruction; it is still inside your wallet, and
`MAX_PROBE_QUESTIONS=10` / `MAX_MATERIAL_ATTEMPTS=3` mean one session is not one
API call.

**Done when:** a full learning session completes in a browser at the staging
hostname against the real LLM, and its measured token cost is recorded here.

**Status: open, and the first finding is that the cluster had no way to reach a
model at all.** The control run (the acceptance walk against a backend still
holding a placeholder key) is what showed it, and the acceptance driver that ran it
is now `scripts/acceptance.py` (`--allow-fail` makes the expected real-mode
failure a result rather than a crash).

- **No egress, and it looked like the familiar problem.** From a pod:
  `api.openai.com` never completed a TCP connection (timeout at 20 s),
  `storage.googleapis.com` answered in 0.1 s, and `example.com`, `github.com`,
  `ipinfo.io` all timed out. The cause is this repository's own shape —
  `enable_private_nodes = true` with no Cloud NAT in the VPC — not the
  mainland-China black-holing AGENTS.md documents. A cloud service that is not
  Google's was unreachable, which the LLM plan quietly assumed away.
  Fixed as code: a Cloud Router and a Cloud NAT gateway over all subnetwork ranges
  (`AUTO_ONLY`, `min_ports_per_vm = 4`). Its price is not asserted here; the
  pricing page is linked in `gcp/network.tf` and M10 reads the line from the bill.
- **The balancer's 30-second backend timeout is a functional limit, not a tuning
  knob.** A still-running request came back as Google's HTML 502 at 30.8 s while
  the pod kept working. `manifests/base/backend-config.yaml` now carries one
  field — `timeoutSec: 120` — attached to the backend Service by annotation. (The
  health-check `BackendConfig`s M6 deleted stay deleted: that field is ignored here,
  this one is the documented mechanism for timeouts.)
- **Two contract facts the walk taught, both now written into the script rather
  than remembered:** the cookie is set by `/auth/login`, not by
  `/auth/register` (the frontend makes both calls); and pydantic's email validator
  rejects a `.invalid` address, so the throwaway learner uses `example.com`.
- **What M8 still needs from you, and it cannot be derived from this repo: which
  endpoint.** The backend's local `.env` points at `http://192.168.200.54:1919/v1`
  with model `qwen3.8-flash-next-iq3_xxs` — a machine on your LAN, unreachable
  from a VPC in `asia-east2`. Whatever production uses has to be reachable from
  the cluster (now possible, via NAT) and is three Secret Manager values:
  `openai-api-key`, `openai-base-url`, `llm-model`. Render's values are not in
  `render.yaml` (`sync: false`), so the dashboard is the only place they exist.
- **Token measurement needs instrumentation that does not exist yet.** The backend
  constructs `ChatOpenAI` in `core/llm.py` and nothing downstream records
  `usage_metadata`, so "tokens per session" is currently unmeasurable in the app.
  When the endpoint is decided, the cheapest honest shape is one callback handler
  attached where the client is built — one line at the construction site, not one
  at each call — logging model, prompt tokens, completion tokens and duration per
  call, and a total per session. Then "measured and written down" is a log read.
- **Staging's half of the Done-when is the part to renegotiate.** A second
  environment with its own public surface is a second address, a second forwarding
  rule and four more pods at the billing floor — roughly doubling the pod line,
  which is over the credit's ceiling. The likely amendment is: run the real-LLM
  session on production (it is already public), and record that. Decide before
  doing it, not by drifting.

## M9 — Cutover, then Render goes away

Decide first whether the Render Postgres data carries over: if it does, `pg_dump`
it and restore into the in-cluster database before the flip. Then repoint, watch,
and only then stop the Render services and delete `render.yaml` and the "Deploy
(Render)" section of the backend README
([CONTEXT.md → cutover](./CONTEXT.md)).

**Done when:** `learn.lotp.xyz` serves a real session, no Render service is
serving traffic, and `render.yaml` no longer exists in the backend repo. The
cutover is also the first time a `pg_dump` archive is read back: do the restore
into the in-cluster database with `pg_restore`, not by hand, so the nightly backup
has been exercised by the time it is the only recovery path (M4 wrote archives;
nothing has restored one yet).

## M10 — Verify the budget claim with numbers

The clock is fixed, so this is arithmetic rather than a feeling. Against
**$3.30/day until 2027-01-06**, read the billed figure at three checkpoints and
commit the actual per-component cost table (the estimates elsewhere in this plan
are estimates):

| checkpoint | date | spend should be under |
|---|---|---|
| first week of real use | 2026-10-14 | ~$23 |
| one third of the window | 2026-11-06 | ~$100 |
| two thirds of the window | 2026-12-06 | ~$200 |

The first checkpoint has one named question to answer before anything else: **is a
GKE cluster-management fee being charged?** ADR 0001 expects it to be waived by the
free tier (one cluster's fee per billing account) and does not assume it. This is
the largest single unknown in the budget at ~$2.40/day, so the first table should
show a GKE row either at $0 with the waiver visible as a credit line, or at the
list rate — and if it is the latter, ADR 0001 is revisited before more is built on
GKE.

Record the **turn-off order** here: what gets switched off first when spend runs
ahead — frontend/sandbox scale-to-zero already handles the rest.

**Done when:** each checkpoint has a dated note in this repo, and either the line
is under the straight-line figure or the plan is amended with the number that
broke it.

## Still assumed, correct me if any of these are wrong

- Inference spend sits outside the 90-day credit and outside the $35/month
  platform ceiling. It is still real money; M8 measures it anyway.
- What happens at day 91 is "start paying": this plan therefore optimises for
  durability and a documented teardown, not for a clean `terraform destroy`.
- No environment beyond `prod` and the scale-to-zero `staging`.
- Whether Render's database holds data worth keeping — unverified; M9 treats it as
  an open decision.
- Per-component cost figures in this plan are estimates I have not verified
  against Google's pricing page: **M1 replaces them with real numbers before M2
  starts.**
- The GKE free-tier fee waiver is assumed to apply to a **free-trial** billing
  account. Sources disagree on whether the waiver follows the trial, and
  Autopilot clusters are always regional, so the zonal-clause wording does not
  cover them either. Unverified; worth $2.40/day; M10 checks it rather than
  trusting it. See the correction in ADR 0001.
- **State location is settled:** `bootstrap/` creates the versioned state bucket
  in `asia-east2`; `gcp/` keeps its state there with the GCS backend, which
  locks states on its own. One local state file remains, in `bootstrap/`, and it
  holds one disposable bucket.
- The Postgres password is generated by Terraform, so it lives in state. The state
  bucket is treated as secret material for that reason: versioning on, no public
  access, readable only by `terraform-local` and the CI identity.
