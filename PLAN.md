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
  ~$3.33 estimate — and the design target I hold myself to is **platform
  ≤ $35/month**, the rest headroom for egress and mistakes.
- **The credit belongs to the billing account, not to this project.** Anything
  else running on `01C0D4-4C9481-8E0DC4` drains the same pot, so M1 creates two
  budgets: one filtered to this project (what the platform actually costs) and one
  unfiltered at account level (what is left of the credit).
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
**budget alerts that include credits**. A monthly budget of the $35 platform
ceiling, alerting at 50/75/100% with `credit_types_treatment =
INCLUDE_ALL_CREDITS`: while the trial credit hides the cost on the bill, the
budget still measures real consumption, which is the whole point of the
90-day constraint. Terraform creates all of it — with one deliberate exception,
and it isn't here (ADR 0004).

**Done when:** `terraform plan` is empty on a re-run; `terraform state list`
shows the cluster, registry, bucket, budgets and service account; `kubectl get
nodes` reports a Ready node.

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
and each one starts under `docker run` and answers its own first route
(`/health` for the backend, `/` for the frontend, `/slides/...` or `/api/compile`
for the sandbox).

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

## M4 — Postgres in-cluster

StatefulSet + PVC + headless Service, its credential generated by Terraform into
Secret Manager, and a nightly `pg_dump` CronJob writing to the GCS bucket
([ADR 0002](./docs/adr/0002-postgres-in-cluster.md)). `postgres:17`, matching
the dev compose file. `DATABASE_URL` handed to the backend in the plain
`postgresql://…` form — the app rewrites the driver scheme itself.

**Done when:** `alembic upgrade head` succeeds against it, and deleting the
database pod leaves the data intact when it comes back.

## M5 — Migrations as a gate

A `Job` that runs `alembic upgrade head`, applied before the Deployment rolls,
so a migration failure blocks the rollout instead of restarting a pod that cannot
reach its schema.

**Done when:** a deliberately broken migration revision makes the deploy fail with
a visible Job log, and the previous Deployment is left serving.

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

## M9 — Cutover, then Render goes away

Decide first whether the Render Postgres data carries over: if it does, `pg_dump`
it and restore into the in-cluster database before the flip. Then repoint, watch,
and only then stop the Render services and delete `render.yaml` and the "Deploy
(Render)" section of the backend README
([CONTEXT.md → cutover](./CONTEXT.md)).

**Done when:** `learn.lotp.xyz` serves a real session, no Render service is
serving traffic, and `render.yaml` no longer exists in the backend repo.

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
- **State location is settled:** `bootstrap/` creates the versioned state bucket
  in `asia-east2`; `gcp/` keeps its state there with the GCS backend, which
  locks states on its own. One local state file remains, in `bootstrap/`, and it
  holds one disposable bucket.
- The Postgres password is generated by Terraform, so it lives in state. The state
  bucket is treated as secret material for that reason: versioning on, no public
  access, readable only by `terraform-local` and the CI identity.
