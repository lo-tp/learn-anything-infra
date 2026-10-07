variable "project_id" {
  description = "The project everything lives in. Created by hand in Step 0, imported below."
  type        = string
}

variable "billing_account_id" {
  description = "Trial billing account. The 90-day credit lives here, not per project."
  type        = string
}

variable "region" {
  description = "Locality constraint: one region, chosen for the free-trial window."
  type        = string
  default     = "asia-east2"
}

variable "cluster_name" {
  type    = string
  default = "learn-anything"
}

variable "image_repositories" {
  description = <<-EOT
    GitHub repositories allowed to push images through the shared deploy identity.
    One pool, one provider per repository, because the condition that makes a
    GitHub OIDC token trustworthy has to name the repository it came from.
  EOT
  type        = list(string)
  default = [
    "lo-tp/learn-anything-backend",
    "lo-tp/learn-anything-frontend",
    "lo-tp/learn-anything-sandbox",
  ]
}

variable "secrets" {
  description = <<-EOT
    Secret *entries*. M1 creates the entries; their values are written by hand or
    by the owning milestone (M4 generates the database password), never by a
    tfvars file in this repo.
  EOT
  type        = list(string)
  default = [
    "jwt-secret",            # shared by backend and frontend: one value
    "sandbox-service-token", # the Sandbox as a service principal (ADR: CONTEXT.md)
    "openai-api-key",
    "openai-base-url",
    "llm-model",
    "db-password",
  ]
}

variable "monthly_platform_budget_usd" {
  description = <<-EOT
    The platform ceiling from PLAN.md, not the credit. The credit is 300 USD over
    91 days to 2027-01-06; inference spend sits outside this figure by your
    instruction.
  EOT
  type        = number
  default     = 35
}

variable "k8s_namespace" {
  description = <<-EOT
    The namespace the production overlay deploys into. It appears in IAM here
    because Workload Identity grants are scoped to a Kubernetes service account in
    a specific namespace (database.tf), so this value and
    manifests/overlays/prod/kustomization.yaml are the same fact stated twice.
    Changing one without the other produces a pod that cannot write to its bucket,
    which is a poor way to find that out — so it is a variable, not a literal.
  EOT
  type        = string
  default     = "learn-anything"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.k8s_namespace))
    error_message = "k8s_namespace must be a valid DNS-1123 label: lowercase alphanumerics and hyphens."
  }
}
