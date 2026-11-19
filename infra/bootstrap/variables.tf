variable "project" {
  description = "Name prefix for every resource."
  type        = string
  default     = "devops-qr"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.project))
    error_message = "project must be lowercase letters, digits and hyphens (it is used in bucket names)."
  }
}

variable "region" {
  description = "AWS region for the state bucket and the ARNs the CI roles may touch."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.region))
    error_message = "region must look like us-east-1."
  }
}

variable "github_repo" {
  description = "GitHub repository as owner/name. Case-sensitive: it must match the OIDC sub claim exactly."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", var.github_repo))
    error_message = "github_repo must be owner/name, e.g. octocat/devops-qr-capstone."
  }
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub Actions OIDC provider. Set false when the account already has one (only one per URL is allowed); the scripts detect this and set the flag."
  type        = bool
  default     = true
}
