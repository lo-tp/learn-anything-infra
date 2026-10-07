# Two more generated values, following the pattern `database.tf` established for
# the database password: the generator, the version, and nothing written into a
# file here.
#
# Both are shared between two of our own services, which is why generating them is
# infrastructure's job — an operator inventing them by hand would produce two
# secrets that have to match across a deploy, and a mismatch between the backend's
# and the frontend's copy of a signing key is a login that never works.
#
# `openai-api-key` and `prompts-token` are deliberately *not* here. They are
# borrowed from outside this project (a vendor key, a repository token): Terraform
# creates the entry, a human supplies the value, and a generated placeholder for
# something only a person can provide would be a lie that deploys successfully.

resource "random_password" "jwt_secret" {
  length  = 48
  special = false

  # Not rotated by editing this resource. Rotating a JWT signing key invalidates
  # every session in every browser at the moment it happens, which at this scale is
  # a decision to make deliberately (and with the backend restarting after it), not
  # a maintenance habit. `keepers` is unset so no plan re-creates it;
  # prevent_destroy makes the one action that would lose it an explicit one.
  keepers = {
    purpose = "learn-anything session signing key"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_secret_manager_secret_version" "jwt_secret" {
  secret      = google_secret_manager_secret.shared["jwt-secret"].id
  secret_data = random_password.jwt_secret.result

  lifecycle {
    create_before_destroy = true
  }
}

resource "random_password" "sandbox_service_token" {
  length  = 48
  special = false

  keepers = {
    purpose = "learn-anything backend to sandbox token"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_secret_manager_secret_version" "sandbox_service_token" {
  secret      = google_secret_manager_secret.shared["sandbox-service-token"].id
  secret_data = random_password.sandbox_service_token.result

  lifecycle {
    create_before_destroy = true
  }
}
