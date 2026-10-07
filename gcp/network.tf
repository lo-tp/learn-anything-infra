resource "google_compute_network" "main" {
  name                    = "learn-anything"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
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
