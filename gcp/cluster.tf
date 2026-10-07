# ADR 0001: Autopilot, because the Standard cluster management fee alone would
# take most of the trial credit. Per-pod billing means the requests written in
# M3 are the bill, not a hint.
resource "google_service_account" "gke_nodes" {
  account_id   = "gke-nodes"
  display_name = "What GKE runs pods as"
}

resource "google_project_iam_member" "gke_nodes" {
  for_each = local.gke_node_roles

  project = var.project_id
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
  role    = each.key
}

resource "google_container_cluster" "main" {
  name             = var.cluster_name
  location         = var.region
  enable_autopilot = true

  network    = google_compute_network.main.id
  subnetwork = google_compute_subnetwork.main.id

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Private nodes; the control plane endpoint stays reachable, because from this
  # network a private-only endpoint means kubectl needs a bastion we do not have.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  release_channel {
    channel = "REGULAR"
  }

  # The Autopilot way to set the node identity. `node_config.service_account` is
  # the deprecated path and the API ignores it here.
  cluster_autoscaling {
    auto_provisioning_defaults {
      service_account = google_service_account.gke_nodes.email
    }
  }

  # A cluster holds the in-cluster Postgres of ADR 0002. Losing it by an
  # incidental `terraform destroy` is not a mistake worth making once.
  deletion_protection = true

  depends_on = [google_project_iam_member.gke_nodes]
}
