# Entries only. Values arrive by another route, and the split is deliberate:
# values that are *ours* are generated (the database password in database.tf, the
# two shared tokens in app_secrets.tf); values that are *borrowed* — the LLM key,
# the prompts repository token — are entered by a person, because generating a
# placeholder for those only hides the fact that nobody has given the value yet.
# M7 is the step that copies whichever kind into Kubernetes Secrets at deploy time.
# No value is ever written into a file in this repo.
resource "google_secret_manager_secret" "shared" {
  for_each = toset(var.secrets)

  # Real dependency, not decoration: with everything in one apply the secret
  # creates race the API enablement and fail with SERVICE_DISABLED. `terraform
  # apply` again succeeds, but a plan that fails half-built is a plan you cannot
  # trust to be idempotent.
  depends_on = [google_project_service.required]

  secret_id = each.value

  replication {
    auto {}
  }

  labels = {
    purpose = "learn-anything"
  }
}
