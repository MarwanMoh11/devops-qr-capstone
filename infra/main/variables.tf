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
  description = "AWS region. az_ids must belong to it."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.region))
    error_message = "region must look like us-east-1."
  }
}

variable "kubernetes_version" {
  description = "EKS Kubernetes minor version. Must be in STANDARD support: extended support costs $0.60/h instead of $0.10/h."
  type        = string
  default     = "1.36"

  validation {
    condition     = can(regex("^1\\.[0-9]{2}$", var.kubernetes_version))
    error_message = "kubernetes_version must be a minor version such as 1.36."
  }
}

variable "admin_principal_arn" {
  description = "IAM role/user ARN granted cluster admin (bootstrap output admin_principal_arn). Fixed so plans by other identities do not churn."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(role|user)/.+$", var.admin_principal_arn))
    error_message = "admin_principal_arn must be an IAM role or user ARN, not an assumed-role session ARN."
  }
}

variable "az_ids" {
  description = "Availability Zone IDs (not names) for the two public subnets. use1-az3 cannot host the EKS control plane."
  type        = list(string)
  default     = ["use1-az1", "use1-az2"]

  validation {
    condition     = length(var.az_ids) == 2 && !contains(var.az_ids, "use1-az3")
    error_message = "Give exactly two AZ IDs, and not use1-az3 (EKS control plane is unsupported there)."
  }
}

variable "vpc_cidr" {
  description = "VPC CIDR. Two /20 public subnets are carved from its start."
  type        = string
  default     = "10.40.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) <= 16
    error_message = "vpc_cidr must be a valid IPv4 CIDR of /16 or larger."
  }
}

variable "node_instance_types" {
  # The defaults work on AWS's Free account plan, which only launches free-tier-eligible
  # types (of those, t3.micro and t3.small have too few pod slots). On a Paid plan,
  # ["t3a.medium", "t3.medium"] is cheaper.
  description = "Node instance types in preference order. x86_64 only (the AMI is AL2023_x86_64_STANDARD) and capped at large to keep cost predictable."
  type        = list(string)
  default     = ["m7i-flex.large", "c7i-flex.large"]

  validation {
    condition = length(var.node_instance_types) > 0 && alltrue([
      for t in var.node_instance_types : can(regex("^(t3a?\\.(medium|large)|[cm]7i-flex\\.large)$", t))
    ])
    error_message = "node_instance_types may only contain t3.medium, t3a.medium, t3.large, t3a.large, m7i-flex.large or c7i-flex.large."
  }
}

variable "node_min" {
  description = "Node group minimum size."
  type        = number
  default     = 1

  validation {
    condition     = var.node_min >= 1
    error_message = "node_min must be at least 1."
  }
}

variable "node_desired" {
  description = "Node group desired size. Pod slots (29 per m7i-flex.large, 17 per t3a.medium) bind first; raise to 3 on 'Too many pods'."
  type        = number
  default     = 2

  validation {
    condition     = var.node_desired >= var.node_min && var.node_desired <= var.node_max
    error_message = "node_desired must be between node_min and node_max."
  }
}

variable "node_max" {
  description = "Node group maximum size. Capped at 4 to bound cost."
  type        = number
  default     = 3

  validation {
    condition     = var.node_max <= 4
    error_message = "node_max above 4 is not expected for this demo."
  }
}

variable "qr_object_expiry_days" {
  description = "Days before generated QR images under qr_codes/ are deleted."
  type        = number
  default     = 7

  validation {
    condition     = var.qr_object_expiry_days >= 1
    error_message = "qr_object_expiry_days must be at least 1."
  }
}
