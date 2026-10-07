resource "google_artifact_registry_repository" "images" {
  location      = var.region
  repository_id = "learn-anything"
  format        = "DOCKER"

  depends_on = [google_project_service.required]

  # Tag retention is a cost control, not housekeeping: unbounded image history is
  # storage that bills quietly next to the things we are trying to afford. Keep
  # the 20 most recent versions per image — enough to roll back a deploy, not
  # enough to accumulate a year of build noise.
  #
  # `action` is `KEEP`, not `DELETE`: the policy states what is *kept*, and the
  # rest is removed. `action = "DELETE"` is accepted by Terraform and rejected by
  # the API, whose error is unhelpful — it echoes the entire repository body and
  # says only "invalid repository". The real message came from the API directly:
  # "mostRecentVersions requires keep action". A dry run would leave the policy
  # configured but never deleting, so it is turned off on purpose.
  cleanup_policy_dry_run = false

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"

    most_recent_versions {
      keep_count = 20
    }
  }

  labels = {
    purpose = "container-images"
  }
}
