# Non-secrets only.
project_id         = "learn-anything-510905"
billing_account_id = "01C0D4-4C9481-8E0DC4"
owner_email        = "no.47wk@gmail.com"
region             = "asia-east2"

# The namespace the production overlay deploys into. Stated here rather than
# left to the default because gcp/database.tf puts this value into IAM, and
# manifests/overlays/prod/kustomization.yaml is the other half of the same fact.
k8s_namespace = "learn-anything"
