# The database's credential, and the identity that is allowed to back it up.
#
# ADR 0002 puts Postgres in the cluster rather than on Cloud SQL, which means the
# credential is ours to create and keep. Terraform generates it because the
# alternative is worse at every level: a hand-made password lives in someone's
# shell history, cannot be rotated by a plan, and is invisible to review.
#
# The generated value ends up in two places and nowhere else: Terraform state
# (which is why the state bucket is treated as secret material — see
# `bootstrap/`), and Secret Manager, from which CI renders the Kubernetes Secret
# (M7). No value in this file, and no value in any file in this repo.

resource "random_password" "database" {
  length  = 32
  special = false

  # `special = false` is not shying away from entropy: 32 alphanumeric characters
  # is more than enough. It is about the place this password has to live — inside
  # a `postgresql://user:pass@host/db` URL. A `@`, `/` or `?` there has to be
  # percent-encoded, and an escaping mistake in a connection string is a strange
  # way to discover that two components disagree about quoting rules.
  #
  # The password is never rotated by editing this resource: `keepers` is unset so
  # a plan will not re-create it, and prevent_destroy means the one action that
  # *would* lose it has to be taken deliberately, by destroying the resource.
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_secret_manager_secret_version" "database" {
  secret      = google_secret_manager_secret.shared["db-password"].id
  secret_data = random_password.database.result

  # Secret Manager versions are immutable and never deleted by this root, so the
  # history of a rotation is the audit trail. The current version is the one GKE
  # is using; the state of that is checked, not assumed (M8).
  lifecycle {
    create_before_destroy = true
  }
}

# ── The backup identity ────────────────────────────────────────
#
# The nightly `pg_dump` CronJob (manifests/base/db-backup.yaml) runs as the
# Kubernetes service account `db-backup` in the application namespace, and GKE
# Workload Identity lets that KSA act as this Google service account. Nothing
# here is a secret: no key file, no token in a manifest. The cluster's own
# workload identity pool — created by GKE with the cluster, named after the
# project, confirmed with `gcloud iam workload-identity-pools list` — is what
# makes the Kubernetes identity assertable.

resource "google_service_account" "db_backup" {
  account_id   = "db-backup"
  display_name = "What the nightly pg_dump CronJob runs as"
}

resource "google_storage_bucket_iam_member" "db_backup_writes" {
  bucket = google_storage_bucket.pgdump.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.db_backup.email}"

  # objectCreator, not objectAdmin: the job writes new objects and never needs to
  # read, list or delete them. Expiry is the bucket's lifecycle rule's job
  # (storage.tf), and restoring is something a person does with their own
  # identity. This is not a theoretical boundary — an earlier version of the job
  # ended with `gcloud storage ls`, and the job failed with exactly this missing
  # permission (`storage.objects.list denied`), which is the clearest possible
  # argument for either widening the grant or, as done, removing the read.
  depends_on = [google_storage_bucket.pgdump]
}

resource "google_service_account_iam_member" "db_backup_workload_identity" {
  service_account_id = google_service_account.db_backup.name
  role               = "roles/iam.workloadIdentityUser"

  # Scoped to one Kubernetes service account in one namespace. The namespace here
  # is a variable precisely because it has to match manifests/overlays/prod;
  # variables.tf says so, and a mismatch shows up as a pod that cannot write to
  # the bucket rather than as a mystery.
  #
  # The member format is the GKE one, not the generic Workload Identity Federation
  # one. Tried and rejected by the API: the `principal://…/ksa/<ns>/<ksa>` form
  # ("Invalid principal member") and the same without the `projects/` prefix
  # ("of an unknown type. Please set a valid type prefix"). The form this project
  # 's GKE pool accepts is `serviceAccount:<PROJECT_ID>.svc.id.goog[<ns>/<ksa>]`,
  # which is also what the GKE docs use. Worth knowing when backend.tf and
  # sandbox.tf need the same kind of grant: copy this, do not copy ci_identity.tf.
  member = "serviceAccount:${var.project_id}.svc.id.goog[${var.k8s_namespace}/db-backup]"
}
