output "cluster_name" {
  value       = google_container_cluster.main.name
  description = "The cluster M3's manifests are applied into."
}

output "image_repository" {
  value       = "${google_artifact_registry_repository.images.location}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
  description = "Where the app repositories push images (M2)."
}

output "workload_identity_providers" {
  value = {
    for repo, p in google_iam_workload_identity_pool_provider.github :
    repo => google_service_account.deploy_ci.email
  }
  description = "Which GitHub repository deploys as which service account."
}

output "state_bucket" {
  value = "learn-anything-tfstate"
}

output "pgdump_bucket" {
  value       = google_storage_bucket.pgdump.name
  description = "Where the nightly pg_dump writes (M4)."
}

output "secret_names" {
  value = [for s in google_secret_manager_secret.shared : s.secret_id]
}
