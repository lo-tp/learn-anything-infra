# ADR 0001: Autopilot, because the Standard cluster management fee alone would
# take most of the trial credit. Per-pod billing means the requests written in
# M3 are the bill, not a hint.
#
# One correction to that reasoning, recorded honestly: Autopilot is not exempt
# from the cluster management fee. GKE bills a cluster-scoped fee for both modes
# (~$0.10/hour, roughly $72/month); what makes it free here is the GKE free tier,
# which waives the fee for one cluster per billing account. Whether a free-trial
# account keeps that waiver is not something these sources settle, and it is worth
# $2.40/day — so M10 checks the billing export for a GKE cluster-management SKU
# before trusting the budget arithmetic. If the fee is real, the levers are a
# zonal Standard cluster with one Spot node (free-tier eligible, but Autopilot
# clusters are always regional) or deleting and re-creating the cluster on demand.
#
# If an apply is interrupted while the cluster is being created, GKE finishes the
# job regardless and the cluster ends up real but outside state — that happened
# once already. Rejoin it rather than letting Terraform create a second cluster:
#
#   terraform import 'google_container_cluster.main' \
#     projects/learn-anything-510905/locations/asia-east2/clusters/learn-anything
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

  depends_on = [
    google_project_iam_member.gke_nodes,
    google_project_service.required,
  ]
}
