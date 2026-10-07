# Entries only. Values arrive by another route (M7: CI reads them and renders
# Kubernetes Secrets; M4 generates the database password), and no value is ever
# written into a file in this repo.
resource "google_secret_manager_secret" "shared" {
  for_each = toset(var.secrets)

  secret_id = each.value

  replication {
    auto {}
  }

  labels = {
    purpose = "learn-anything"
  }
}
