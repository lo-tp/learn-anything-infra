# Two more generated values, following the pattern `database.tf` established for
# the database password: the generator, the version, and nothing written into a
# file here.
#
# Both exist so that a value one service holds and another must agree with is
# generated once rather than invented twice: `sandbox-service-token` is read by
# the backend and the sandbox, and a hand-written mismatch between the two is a
# `/slides/{id}` that 401s. `jwt-secret` used to be shared the same way (backend
# and frontend); since the frontend stopped verifying the cookie (#149) the
# backend is its only reader, but it is still generated here — rotating it is the
# one act that invalidates every signed-in browser, and that should stay a
# deliberate act with a generated value behind it.
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
