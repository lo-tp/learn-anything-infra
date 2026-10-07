# Never the state bucket: different retention, and one bad `terraform destroy`
# should not be able to reach the only copy of the data (ADR 0002, PLAN.md M4).
resource "google_storage_bucket" "pgdump" {
  name                        = "learn-anything-pgdump"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # The nightly dump CronJob writes dated objects here; 30 days of them is a
  # restore ladder without a storage line worth mentioning.
  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = 30
    }
  }

  labels = {
    purpose = "postgres-backups"
  }
}
