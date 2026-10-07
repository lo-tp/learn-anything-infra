provider "google" {
  project = var.project_id

  # API calls are billed against this project. With a trial credit that is the
  # difference between the credit paying and you paying.
  billing_project = var.project_id

  region = var.region
  zone   = "${var.region}-a"
}
