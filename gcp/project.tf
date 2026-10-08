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
# drift: docs/plan/step-0-the-three-things-only-you-can-do.md names those bootstrap acts so nobody treats them as surprises.
#
# Everything that calls a Google API has to wait for its API to be enabled, which
# is why the consumers in the other files carry `depends_on` on this collection.
# That is not style: the first apply created secrets, a repository, a network and
# two budgets in the same pass as these `google_project_service` resources, and
# Google answered several of them with 403 "API has not been used in project …
# before or it is disabled". The apply half-succeeded, which is the worst outcome
# an infrastructure change can have: a plan you cannot trust to be idempotent.
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
    "billingbudgets.googleapis.com",
    "serviceusage.googleapis.com",
    "storage.googleapis.com",
    "servicenetworking.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}
