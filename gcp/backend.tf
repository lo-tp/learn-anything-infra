# Printed by bootstrap/ (`terraform output -raw backend_config`) rather than
# remembered. A backend belongs inside a terraform block, so it is its own file
# here and not a stanza in versions.tf. The GCS backend locks states on its own,
# so a half-applied state cannot happen.
terraform {
  backend "gcs" {
    bucket = "learn-anything-tfstate"
    prefix = "gcp"
  }
}
