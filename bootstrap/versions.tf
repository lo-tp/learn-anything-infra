terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0"
    }
  }

  # The one local state in this repo: it holds the bucket that holds every other
  # state. See README.md.
  backend "local" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}
