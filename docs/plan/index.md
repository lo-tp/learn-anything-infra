# Plan: deploy Learn Anything on GCP with Terraform + Kubernetes

The ordered path from "four repos, one of them empty" to "Learn Anything runs at
`learn.lotp.xyz`, described entirely in this repo, and Render is gone."

Each milestone ends on a **completion criterion** — the condition that says it is
done. Do the milestones in order; each one's criterion is the next one's
foundation. The *why* behind each load-bearing choice lives in
[`docs/adr/`](../adr/), not here. The words used here are defined in
[`CONTEXT.md`](../../CONTEXT.md).

**How to read this, now that most of it is built.** This is a working document, not
a status page, and that has two consequences. What production *runs* is never
recorded here: the record is `images:` in
`manifests/overlays/prod/kustomization.yaml`, and nothing in this plan is
authoritative about digests. And a `**Status: done…**` paragraph is a dated
finding — what was measured, on what date, and what the system did that the design
did not predict — kept deliberately, because those findings are why several
decisions in [`docs/adr/`](../adr/) say what they say.

**You are reading the plan's index.** The milestones are one file each in this
 directory, named
`step-0`, `m01` … `m10`. This file holds what the whole plan depends on and
nothing else: the inputs, the order, and the assumptions. A milestone file carries
its own criterion, its findings and its `Status:` paragraph; when they disagree
with the table below, **the milestone file is right** — that table is navigation,
not a record.

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
  ([ADR 0004](../adr/0004-dns-stays-at-namecheap.md)). `blog.lotp.xyz` →
  `lo-tp.github.io` is a **foreign record**: never touched, and untouched by this
  plan. The apex and `www.` have no records today; leave them that way.
- **Terraform drives everything; `gcloud` creates nothing.** The rule, and the one
   thing it doesn't cover (the credential helper `kubectl` needs), is in
   [`AGENTS.md`](../../AGENTS.md). Three things stay outside Terraform's reach: the
   **DNS records** ([ADR 0004](../adr/0004-dns-stays-at-namecheap.md)), the
   **BigQuery billing export** (a console setting with no API, not backfilled, which
   `make cost-report` reads), and the **free-trial signup** (no API at all). The
   first two are declared here so their drift is checkable. They are walked in
   Step 0 (the trial), M6 (the records) and M10 (the export).
- **Nothing was deployed here when this plan began**; the only deployment the
  product had was the Render blueprint in the backend repo, and that is what this
  plan was leaving. It has since been deleted (M9).

## The milestones, in order

They are listed in the order they were done, which is the order they must be read:
each milestone's completion criterion is the assumption the next one runs on, and
skipping to M10 without M2's image contract produces confident nonsense.

| | for | where it stands |
|---|---|---|
| [Step 0](./step-0-the-three-things-only-you-can-do.md) | the three acts only a human can do: the trial, the project and its service account, the state bucket | complete |
| [M1](./m01-terraform-foundation.md) | Terraform owns everything: cluster, APIs, network, registry, buckets, Secret Manager, Workload Identity, budgets | applied, and idempotent |
| [M2](./m02-images-this-is-where-the-work-actually-is.md) | an image per app, built and smoke-tested **in its own repository**, pinned here by digest | all three published and verified by their own workflows |
| [M3](./m03-workloads-as-kustomize-base-overlays.md) | workloads as a Kustomize base with `prod`/`staging` overlays — and the scale-to-zero design examined rather than assumed | applied; the design was amended by measurement |
| [M4](./m04-postgres-in-cluster.md) | PostgreSQL in-cluster on a persistent disk, with a nightly dump to object storage | applied; the gate passes |
| [M5](./m05-migrations-as-a-gate.md) | a migration Job that gates every rollout, so a failed schema change cannot reach a serving workload | works in both directions |
| [M6](./m06-one-public-surface-three-hostnames-real-certificates.md) | one address, three hostnames, a managed certificate, and DNS records declared here and typed by hand | done; every clause of the gate executed |
| [M7](./m07-secrets-to-pods.md) | secret values from Secret Manager into pods, and the CI pipeline that applies manifests with its own identity | done, including the first real CI deploy |
| [M8](./m08-prove-it-then-let-it-use-the-real-llm.md) | prove a real session end to end through the public surface, then point it at a real model | open: egress fixed, endpoint and region still not |
| [M9](./m09-cutover-then-render-goes-away.md) | cutover, the restore drill, and Render being switched off | partly done; one clause needs a hand at a dashboard |
| [M10](./m10-verify-the-budget-claim-with-numbers.md) | replace every cost estimate in this plan with billed figures, and record the turn-off order | measurement path built; the first table awaits the billing export |

There is no M11. What remains is the open columns above, and the checkpoints in
M10.

## Assumptions this plan rested on, and where each stands now

Listed because an assumption that has been quietly replaced is worse than one that
was wrong. Several below are settled; the line says how.

- Inference spend sits outside the 90-day credit and outside the platform ceiling.
  It is still real money; M8 measures it anyway. *(Held; restated by the user on
  2026-10-08.)*
- What happens at day 91 is "start paying": this plan therefore optimises for
  durability and a documented teardown, not for a clean `terraform destroy`.
- No environment beyond `prod` and the scale-to-zero `staging`. *(Recorded as a
  decision: [ADR 0006](../adr/0006-one-environment-until-the-second-is-priced.md).)*
- Whether Render's database holds data worth keeping — **decided on 2026-10-08:
  no.** No carryover; the in-cluster database is the only one (see M9, and
  [ADR 0005](../adr/0005-no-render-data-carries-over.md)).
- Per-component cost figures in this plan were estimates that had not been checked
  against Google's pricing page. *(Replaced wherever measurement was possible: the
  option table and the floor arithmetic in M3 came from the live cluster's requests,
  not from the pricing page. What no measurement can replace is the billed figure,
  which is M10's job — and `make cost-report` refuses to invent one.)*
- The GKE free-tier fee waiver is assumed to apply to a **free-trial** billing
  account. Sources disagree on whether the waiver follows the trial, and
  Autopilot clusters are always regional, so the zonal-clause wording does not
  cover them either. **Still unverified**; worth about $2.40/day, so the first cost
  table must show a GKE row, and ADR 0001 is revisited if that row is not $0. See
  the correction in ADR 0001.
- **State location is settled:** `bootstrap/` creates the versioned state bucket in
  `asia-east2`; `gcp/` keeps its state there with the GCS backend, which locks
  states on its own. One local state file remains, in `bootstrap/`, and it holds one
  disposable bucket. *(Applied; both roots are idempotent under `terraform apply`.)*
- The Postgres password is generated by Terraform, so it lives in state. The state
  bucket is treated as secret material for that reason: versioning on, no public
  access, readable only by `terraform-local` and the CI identity.
