# The state bucket. Versioning is the undo button for a bad apply: state is a few
# hundred KB, so keeping every version costs nothing and buys a way back.
resource "google_storage_bucket" "tfstate" {
  name     = var.state_bucket
  location = var.region

  # State carries secrets — the generated Postgres password among them (ADR 0002).
  # Nothing about this bucket may be public, and access is decided by IAM alone.
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  labels = {
    purpose = "terraform-state"
  }

  # Deliberately no lifecycle/deletion rule: a rule that ages out old state also
  # ages out the recovery. Losing this bucket outright would not lose the
  # infrastructure, but it would make it unmanaged until re-imported.
}
