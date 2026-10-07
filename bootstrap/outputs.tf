output "state_bucket" {
  description = "The bucket every other root points its backend at."
  value       = google_storage_bucket.tfstate.name
}

# The exact block to copy into gcp/backend.tf. Printed rather than remembered, so
# the two never drift.
output "backend_config" {
  description = "backend block for the next root."
  value = join("\n", [
    "backend \"gcs\" {",
    "  bucket = \"${google_storage_bucket.tfstate.name}\"",
    "  prefix = \"gcp\"",
    "}",
  ])
}
