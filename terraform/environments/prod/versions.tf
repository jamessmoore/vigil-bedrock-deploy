terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Remote state in S3 with native state locking (use_lockfile, TF >= 1.10) —
  # no DynamoDB table required. Fill in via -backend-config or backend.hcl;
  # values are intentionally not committed. See README "Remote state".
  backend "s3" {
    # bucket       = "your-tf-state-bucket"
    # key          = "vigil-bedrock-deploy/prod/terraform.tfstate"
    # region       = "us-east-1"
    # encrypt      = true
    # use_lockfile = true
  }
}
