# Creates the S3 bucket that holds the main configuration's state (SPEC
# §12). Run once, with local state: the main configuration can't create the
# bucket its own state lives in.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "movie-night"
      ManagedBy = "opentofu"
    }
  }
}

data "aws_caller_identity" "current" {}

# Bucket names are global, so the account ID keeps this one unique.
resource "aws_s3_bucket" "state" {
  bucket = "movie-night-tofu-state-${data.aws_caller_identity.current.account_id}"

  lifecycle {
    prevent_destroy = true
  }
}

# Versioning keeps earlier states, so a bad apply can be rolled back.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Old state versions are tiny, but there's no reason to keep them forever.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

output "state_bucket" {
  description = "Put this in infra/backend.hcl as the bucket."
  value       = aws_s3_bucket.state.bucket
}
