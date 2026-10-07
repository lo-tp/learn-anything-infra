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

output "ingress_ip" {
  description = <<-EOT
    The address every public surface resolves to, reserved by name in
    gcp/ingress.tf. The Ingress annotation refers to it by name
    (learn-anything-ingress-ip); this output is for the human who types it into a
    DNS dashboard.
  EOT
  value       = google_compute_global_address.ingress_ip.address
}

output "dns_records" {
  description = <<-EOT
    Exactly the rows that belong in the registrar's Advanced DNS: name, type,
    value, TTL. When the dashboard and this list disagree, this repo is right and
    the dashboard is wrong (docs/adr/0004-dns-stays-at-namecheap.md).
  EOT
  value = join("\n", [
    for h in local.live_hosts : format(
      "  %-26s A      %-15s TTL %s",
      h, google_compute_global_address.ingress_ip.address, var.dns_ttl_seconds
    )
  ])
}

output "dns_records_deferred" {
  description = <<-EOT
    Declared, not pointed: the staging hosts, which have no load balancer behind
    them until M9 decides a second address and forwarding rule are worth the
    monthly line. They are printed here rather than left out, because a name that
    exists only in someone's memory is how a certificate ends up not covering it.
  EOT
  value = join("\n", [
    for h in local.deferred_hosts : format(
      "  %-26s A      %-15s TTL %s   (not typed yet: no ingress for staging)",
      h, google_compute_global_address.ingress_ip.address, var.dns_ttl_seconds
    )
  ])
}

output "dns_records_foreign" {
  description = <<-EOT
    What is on the zone but not ours. Print this before touching the dashboard.
  EOT
  value = join("\n", [
    for r in var.dns_foreign_records : format(
      "  %-26s %-6s %-15s  %s", "${r.name}.${var.dns_zone}", r.type, r.value, r.why
    )
  ])
}

output "certificate_hosts" {
  description = <<-EOT
    Every host the one managed certificate has to cover. The certificate and the
    Ingress live in the manifests, so this output is what those files are checked
    against (scripts/dns-check.sh) rather than a second place to remember them.
    Staging is not in this list because nothing is asked to cover it yet.
  EOT
  value       = local.live_hosts
}
