# Step 0 — the three things only you can do

← [plan index](./index.md) · next [M1](./m01-terraform-foundation.md)

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
   console. Without it the 90-day limit in [M10](./m10-verify-the-budget-claim-with-numbers.md) has no start.
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

   The eleven granular bindings below are now **mine, in Terraform**, in [M1](./m01-terraform-foundation.md) —
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
makes local image pushes work in [M2](./m02-images-this-is-where-the-work-actually-is.md); note that Docker Desktop needs its own proxy
setting, separate from the shell's.

Terraform and `kubectl` must go through the local HTTP proxy; see *Network* in
[`AGENTS.md`](../../AGENTS.md), and `make tf-plan` / `make tf-apply` set it for you.

**Status: complete.** Every item above is done and verified, and the credit's
expiry date (2027-01-06) is recorded in *Inputs* with the window it implies.
`bootstrap/` has been applied: `learn-anything-tfstate` exists in `ASIA-EAST2`, and reading it back
from the API confirms `versioning_enabled: true`, `public_access_prevention:
enforced`, `uniform_bucket_level_access: true`. Its outputs print the `backend
"gcs"` block that `gcp/` will use.

Two APIs — `cloudbilling` and `cloudresourcemanager` — were enabled during this
bootstrap because the bootstrap could not read or grant anything without them.
That is **not drift**: `google_project_service` in [M1](./m01-terraform-foundation.md) declares them too, and
declaring an already-enabled service is a no-op.

**Done when:** the expiry date is recorded here. Everything else in this step is
verifiable in the outputs above.
