terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # State lives in the bucket made by infra/bootstrap. The bucket name is
  # supplied at init time: tofu init -backend-config=backend.hcl
  backend "s3" {
    key          = "movie-night/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project   = "movie-night"
      ManagedBy = "opentofu"
    }
  }
}
