variable "project_id" {
  description = "The GCP project that owns everything, including this state bucket."
  type        = string
}

variable "region" {
  description = "Locality constraint: every resource in this project stays in one region."
  type        = string
  default     = "asia-east2"
}

variable "state_bucket" {
  description = "Name of the bucket that will hold Terraform state."
  type        = string
  default     = "learn-anything-tfstate"
}
