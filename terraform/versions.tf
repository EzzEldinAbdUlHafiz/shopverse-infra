terraform {
  # >= 1.10 is required to use use_lockfile = true (native S3 state locking),
  # which is enabled in backend.tf. Keep this in lockstep with the bootstrap
  # module's required_version so the whole stack shares the same floor.
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}
