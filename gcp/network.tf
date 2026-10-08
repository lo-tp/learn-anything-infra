resource "google_compute_network" "main" {
  name                    = "learn-anything"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"

  depends_on = [google_project_service.required]
}

# VPC-native is required for Autopilot: pods and services get secondary ranges
# rather than stolen primary IPs.
resource "google_compute_subnetwork" "main" {
  name          = "learn-anything-${var.region}"
  region        = var.region
  network       = google_compute_network.main.id
  ip_cidr_range = "10.10.0.0/20"

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.20.0.0/16"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.21.0.0/20"
  }
}

# A Cloud Router is the thing a Cloud NAT gateway attaches to; it announces no
# routes of its own here. It exists because of the line in cluster.tf that reads
# `enable_private_nodes = true`: nodes with no external address have no path to
# the internet unless something in the VPC translates their traffic.
resource "google_compute_router" "main" {
  name    = "learn-anything-${var.region}"
  network = google_compute_network.main.id
  region  = var.region
}

# Why this exists, in one measured sentence: from a pod in this cluster,
# `https://api.openai.com/v1/models` timed out at 20s (TCP never connected) while
# `https://storage.googleapis.com` answered in 0.1s. That is not the mainland-China
# problem AGENTS.md describes — it is this missing NAT, and it looked exactly like
# the other one. The product's only deliberate outbound dependency is the LLM
# endpoint (M8), so without it the backend can reach no model that is not inside
# Google.
#
# What it costs is not assumed here: Cloud NAT is billed per gateway VM-hour and
# per GB processed, and the current rates are
# https://cloud.google.com/vpc/network-pricing#nat-pricing. LLM traffic is
# kilobytes per call, so the egress term is noise; the gateway term is the one to
# watch, and M10 reads it from the bill rather than from this comment.
resource "google_compute_router_nat" "main" {
  name                               = "learn-anything-egress"
  router                             = google_compute_router.main.name
  region                             = var.region
  # Auto-allocated Google-owned addresses: a listed-NAT configuration would mean
  # paying for static external IPs we have no reason to pin.
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
  # The default 10-minimum endpoint count is more than a four-pod cluster needs,
  # and the minimum is a billed unit. Small on purpose; nothing here is
  # throughput-bound except a model's own latency.
  min_ports_per_vm = 4
  drain_nat_ips    = []
  # No tcp/udp timeout arguments in this provider version — the plan says so, and
  # the API's defaults (120 s TCP) are what we would have chosen anyway.

  depends_on = [google_compute_subnetwork.main]
}
