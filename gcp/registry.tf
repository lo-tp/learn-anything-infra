resource "google_artifact_registry_repository" "images" {
  location      = var.region
  repository_id = "learn-anything"
  format        = "DOCKER"

  # Tag retention is a cost control, not housekeeping: unbounded image history is
  # storage that bills quietly next to the things we are trying to afford. Keep
  # the 20 most recent versions per image — enough to roll back a deploy, not
  # enough to accumulate a year of build noise.
  cleanup_policies {
    id     = "keep-recent"
    action = "DELETE"

    most_recent_versions {
      keep_count = 20
    }
  }

  labels = {
    purpose = "container-images"
  }
}
