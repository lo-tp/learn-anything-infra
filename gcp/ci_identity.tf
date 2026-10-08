# The deploy identity: CI, with no key file. GitHub's OIDC token is exchanged for
# short-lived credentials against this service account, which holds the narrow set
# of permissions a deploy needs and nothing else.
resource "google_service_account" "deploy_ci" {
  account_id   = "deploy-ci"
  display_name = "GitHub Actions deploys"
}

resource "google_project_iam_member" "deploy_ci" {
  for_each = local.deploy_ci_roles

  project = var.project_id
  member  = "serviceAccount:${google_service_account.deploy_ci.email}"
  role    = each.key
}

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "learn-anything-github"
  description               = "GitHub Actions, for this project's repositories only"
}

# One provider per repository: the assertion that makes a GitHub token trustworthy
# has to name the repository it came from, and each pipeline has its own identity.
#
# `attribute_mapping` is not optional for OIDC providers — Google rejects the
# create with "Attribute mappings are required for OIDC providers". Mapping
# `attribute.repository` is also what makes the workload grant below stable: a
# `principalSet` grant on the repository matches any branch or environment, where
# the default `google.subject` (`repo:<repo>:refs/heads/<branch>`) would tie the
# grant to one branch.
resource "google_iam_workload_identity_pool_provider" "github" {
  for_each = toset(var.ci_repositories)

  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = replace(each.value, "/", "-")

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.actor"      = "assertion.actor"
    "attribute.repository" = "assertion.repository"
  }

  attribute_condition = "assertion.repository == \"${each.value}\" && assertion.repository_owner == \"lo-tp\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }

  depends_on = [google_project_service.required]
}

# Keys come from the variable, not from the provider resources: iterating over
# resource attributes leaves the key set unknown at plan time, which Terraform
# refuses rather than guessing.
resource "google_service_account_iam_member" "deploy_ci_workload" {
  for_each = toset(var.ci_repositories)

  service_account_id = google_service_account.deploy_ci.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${each.value}"

  depends_on = [google_iam_workload_identity_pool_provider.github]
}
