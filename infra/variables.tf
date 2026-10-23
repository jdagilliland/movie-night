variable "region" {
  type    = string
  default = "us-east-1"
}

variable "availability_zone" {
  description = "The instance and its data volume must share an AZ. t4g isn't offered in every one."
  type        = string
  default     = "us-east-1a"
}

variable "domain" {
  description = "Public domain for the app, e.g. paste.example.com. Its DNS A record must point at the Elastic IP."
  type        = string
}

variable "route53_zone_name" {
  description = "A Route 53 hosted zone in this account (e.g. example.com) in which to manage the A record for domain. Leave null to manage DNS elsewhere."
  type        = string
  default     = null
}

variable "github_repository" {
  description = "owner/name of the GitHub repository allowed to push images."
  type        = string
  default     = "jdagilliland/movie-night"
}

variable "ssh_public_key" {
  description = "Public key for SSH access as the ubuntu user (the contents, not a path)."
  type        = string
}

variable "admin_cidrs" {
  description = "CIDRs allowed to SSH in, e.g. [\"203.0.113.7/32\"]."
  type        = list(string)
}

variable "alert_email" {
  description = "Where budget alerts are sent."
  type        = string
}

variable "instance_type" {
  description = "t4g.nano (0.5 GB, with a 1 GB swap file) keeps the monthly cost under the budget."
  type        = string
  default     = "t4g.nano"
}

variable "data_volume_size_gb" {
  type    = number
  default = 1
}

variable "snapshot_retention" {
  description = "How many daily snapshots of the data volume to keep."
  type        = number
  default     = 7
}

variable "monthly_budget_usd" {
  type    = number
  default = 10
}

variable "paste_ttl_days" {
  description = "Lifetime of newly created pastes (PASTE_TTL_DAYS)."
  type        = number
  default     = 30
}
