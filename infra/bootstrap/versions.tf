terraform {
  # use_lockfile on the main stack's S3 backend needs >= 1.10.
  required_version = ">= 1.10, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # No backend block: bootstrap keeps LOCAL state (gitignored). It creates the
  # bucket that the main stack uses as its backend, so it cannot live in it.
}
