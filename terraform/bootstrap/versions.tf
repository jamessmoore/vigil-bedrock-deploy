terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # Bootstrap uses LOCAL state by design: it creates the very S3 bucket the
  # main stack uses as its backend, so it can't store its own state there
  # (chicken-and-egg). Run once by an admin; keep the resulting
  # terraform.tfstate safe — it contains the deployer's secret access key.
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}
