variable "project_name" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

# --- Security groups (one per service) ---
variable "backend_security_group_id" {
  type = string
}
variable "soc_daemon_security_group_id" {
  type = string
}
variable "llm_worker_security_group_id" {
  type = string
}
variable "bifrost_security_group_id" {
  type = string
}

# --- Load balancer target groups ---
variable "backend_target_group_arn" {
  type = string
}
variable "soc_daemon_target_group_arn" {
  type = string
}

# --- Container images ---
variable "backend_image" {
  description = "Full ECR image reference for the Vigil backend (repo:tag), built from the pinned fork ref."
  type        = string
}
variable "daemon_image" {
  description = "Full ECR image reference for the Vigil soc-daemon (repo:tag)."
  type        = string
}
variable "bifrost_image" {
  description = "Bifrost gateway image — pinned Docker Hub tag (e.g. maximhq/bifrost:v1.5.16)."
  type        = string
  default     = "maximhq/bifrost:v1.5.16"
}
variable "config_init_image" {
  description = "Tiny image used only to seed Bifrost's config.json into a shared volume. Pulled from public ECR to avoid Docker Hub rate limits on Fargate."
  type        = string
  default     = "public.ecr.aws/docker/library/busybox:1.36"
}

# --- Data layer connection ---
variable "db_endpoint" {
  type = string
}
variable "db_port" {
  type = number
}
variable "db_name" {
  type = string
}
variable "db_username" {
  type = string
}
variable "db_master_secret_arn" {
  description = "Secrets Manager ARN of the RDS-managed master credentials (JSON with a `password` key)."
  type        = string
}
variable "redis_endpoint" {
  type = string
}
variable "redis_port" {
  type = number
}

# --- Bifrost fallback-provider secrets ---
variable "anthropic_secret_arn" {
  type = string
}
variable "openai_secret_arn" {
  type = string
}

# --- Bedrock model targeting (the project's thesis) ---
variable "bedrock_sonnet_model_id" {
  description = <<-EOT
    The exact Bedrock model identifier Bifrost routes Claude Sonnet 4.6 traffic to.
    For cross-region inference this is the inference-profile ID, e.g.
    "us.anthropic.claude-sonnet-4-6-YYYYMMDD-v1:0". Look up the real value with:
      aws bedrock list-inference-profiles --region <region> \
        --query "inferenceProfileSummaries[?contains(inferenceProfileName,'Sonnet 4.6')]"
    Do not guess the dated suffix — confirm it against your account/region.
  EOT
  type        = string
}

variable "bedrock_invoke_resource_arns" {
  description = <<-EOT
    Bedrock ARNs the Bifrost task role may invoke. For a cross-region inference
    profile you must include BOTH the inference-profile ARN and every underlying
    foundation-model ARN the profile fans out to (one per region), e.g.:
      arn:aws:bedrock:us-east-1:<acct>:inference-profile/us.anthropic.claude-sonnet-4-6-YYYYMMDD-v1:0
      arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-6-YYYYMMDD-v1:0
      arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-sonnet-4-6-YYYYMMDD-v1:0
    Scope this list explicitly — never "*".
  EOT
  type        = list(string)
}

# --- Sizing ---
variable "task_cpu" {
  type    = number
  default = 512
}
variable "task_memory" {
  type    = number
  default = 1024
}
variable "desired_count" {
  type    = number
  default = 1
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "tags" {
  type    = map(string)
  default = {}
}
