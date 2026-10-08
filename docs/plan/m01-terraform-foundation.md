# M1 — Terraform foundation

← [plan index](./index.md) · [Step 0](./step-0-the-three-things-only-you-can-do.md) · next [M2](./m02-images-this-is-where-the-work-actually-is.md)

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
