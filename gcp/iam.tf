# PLAN.md Step 0 lists these and why each one is needed. They live here rather
# than as `gcloud` grants because an IAM binding is configuration: granted from a
# shell it is invisible to `terraform plan` and unanswerable from the repo.
locals {
  terraform_local_roles = {
    "roles/container.admin"                 = "GKE"
    "roles/compute.networkAdmin"            = "the VPC and subnetwork"
    "roles/artifactregistry.admin"          = "image repository"
    "roles/storage.admin"                   = "state and pg_dump buckets"
    "roles/secretmanager.admin"             = "secrets (M7)"
    "roles/serviceusage.serviceUsageAdmin"  = "enabling APIs"
    "roles/iam.serviceAccountAdmin"         = "the CI and node identities"
    "roles/iam.serviceAccountUser"          = "granting those to workloads"
    "roles/resourcemanager.projectIamAdmin" = "GKE grants roles to its own agents"
  }

  deploy_ci_roles = {
    "roles/artifactregistry.writer"      = "push images"
    "roles/container.developer"          = "apply workloads"
    "roles/secretmanager.secretAccessor" = "render Secrets at deploy time (M7)"
  }

  gke_node_roles = {
    "roles/logging.logWriter"       = "container logs"
    "roles/monitoring.metricWriter" = "container metrics"
    "roles/monitoring.viewer"       = "read what Cloud Ops shows"
    "roles/artifactregistry.reader" = "pull images from the repository"
  }
}

resource "google_project_iam_member" "terraform_local" {
  for_each = local.terraform_local_roles

  project = var.project_id
  member  = "serviceAccount:${google_service_account.terraform_local.email}"
  role    = each.key
}

# Deliberate: the human identity holds owner; the automation does not. The SA was
# given owner only to bootstrap itself (Step 0), and broad authority is exactly
# what this file replaces. Authoritative for this one role, so it also removes the
# SA's owner binding.
resource "google_project_iam_binding" "project_owner" {
  project = var.project_id
  role    = "roles/owner"
  members = ["user:${var.owner_email}"]

  # Ordering matters: if the additive bindings above fail and this one succeeds,
  # the automation loses owner before it ever gained what it needs in its place.
  depends_on = [google_project_iam_member.terraform_local]
}

resource "google_service_account" "terraform_local" {
  account_id   = "terraform-local"
  display_name = "Terraform, run from a laptop"
}
