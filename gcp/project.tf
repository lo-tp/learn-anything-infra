# The project was created by hand in Step 0, so it is imported rather than
# created. Until it is in state Terraform cannot attach billing or set project
# settings, and the project sits outside the one place everything else is
# described.
#
#   terraform import google_project.main learn-anything-510905
#
resource "google_project" "main" {
  project_id          = var.project_id
  name                = "learn-anything"
  billing_account     = var.billing_account_id
  deletion_policy     = "PREVENT"
  auto_create_network = false

  labels = {
    purpose = "learn-anything"
  }
}

# Declaring an API that the Step 0 bootstrap already enabled is a no-op, not
# drift: PLAN.md names those bootstrap acts so nobody treats them as surprises.
resource "google_project_service" "required" {
  for_each = toset([
    "container.googleapis.com",
    "compute.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "cloudbilling.googleapis.com",
    "serviceusage.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}
