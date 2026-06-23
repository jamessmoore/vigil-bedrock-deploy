variable "aws_region" {
  description = "Region for the state bucket. Should match the main stack's region."
  type        = string
  default     = "us-west-2"
}

variable "project_name" {
  description = "Resource name prefix the main stack uses. IAM/secret scoping keys off this."
  type        = string
  default     = "vigil"
}

variable "state_bucket_name" {
  description = "Globally-unique name for the main stack's Terraform state bucket."
  type        = string
  default     = "vigil-bedrock-deploy-tfstate-293528978619"
}

variable "deployer_user_name" {
  description = "IAM user that runs the main stack's terraform apply."
  type        = string
  default     = "vigil-deployer"
}

variable "create_access_key" {
  description = "Whether to mint a long-lived access key for the deployer user (stored in bootstrap state). Set false if you'd rather mint it out-of-band with `aws iam create-access-key`."
  type        = bool
  default     = true
}
