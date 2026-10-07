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

variable "dns_zone" {
  description = <<-EOT
    The zone the public surfaces live on. Namecheap's dashboard wants each record's
    name relative to the zone ("learn"), which is why the outputs join host to zone
    rather than storing fully-qualified names here.
  EOT
  type        = string
  default     = "lotp.xyz"
}

variable "public_hostnames" {
  description = <<-EOT
    The production surfaces: the app, its API, and the sandbox's slide frames. These
    are the rows that belong in the registrar, and the names the certificate must
    cover. Declared here because a certificate, an Ingress and a DNS row are three
    spellings of one decision, and the disagreement between them is a 503 with a
    valid cert.
  EOT
  type        = list(string)
  default     = ["learn", "api", "sandbox"]
}

variable "staging_hostnames" {
  description = <<-EOT
    The staging variants, named the same way rather than as a sub-zone: one level,
    one cert, no second zone to delegate. See PLAN.md M6.
  EOT
  type        = list(string)
  default     = ["staging.learn", "staging.api", "staging.sandbox"]
}

variable "dns_foreign_records" {
  description = <<-EOT
    Records on this zone that this project does not own — CONTEXT.md's *foreign
    record*. They are listed so that `terraform output dns_records_foreign` can say
    "leave this alone" out loud when someone is elbow-deep in the dashboard, not so
    that Terraform can manage them: it cannot, and it should not try.
  EOT
  type = list(object({
    name  = string
    type  = string
    value = string
    why   = string
  }))
  default = [
    {
      name  = "blog"
      type  = "CNAME"
      value = "lo-tp.github.io"
      why   = "GitHub Pages. Read it, preserve it, never edit it."
    },
  ]
}

variable "dns_ttl_seconds" {
  description = <<-EOT
    The TTL to type into the registrar. Short on purpose: during a cutover the
    records are the thing being changed, and a 30-minute default is a 30-minute
    wait to find out whether the change worked. Namecheap offers 5 min; anything
    shorter is a rounding error against a hand-edited dashboard.
  EOT
  type        = number
  default     = 300
}
