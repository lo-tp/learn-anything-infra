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

output "workload_identity_provider_names" {
  value = {
    for repo, p in google_iam_workload_identity_pool_provider.github :
    repo => p.name
  }
  description = <<-EOT
    The provider resource path each repository's CI job puts in
    `workload_identity_provider:`. Printed rather than hand-written because the
    canonical name is `projects/<PROJECT_NUMBER>/…`: STS answers a
    `projects/<PROJECT_ID>/…` audience with `invalid_target` (“pool or provider is
    disabled or deleted or … doesn't exist”), which reads like the resource is
    missing when it is present and active. One workflow learned that the hard way;
    this output is how the other two do not have to.
  EOT
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

output "project_id" {
  description = <<-EOT
    Read out rather than assumed: the render step (scripts/render-secrets.sh) needs
    it to address Secret Manager, and a project id copied by hand into a script is
    a second source of a fact Terraform already knows.
  EOT
  value       = google_project.main.project_id
}

output "k8s_namespace" {
  description = <<-EOT
    The namespace the production overlay deploys into, next to the IAM grants that
    name it. If this and manifests/overlays/prod/kustomization.yaml disagree, that
    is visible here rather than in a pod that cannot reach its bucket.
  EOT
  value       = var.k8s_namespace
}
