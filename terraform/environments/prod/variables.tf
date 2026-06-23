variable "aws_region" {
  description = "AWS region for the whole deploy. Must be a region where Bedrock Claude Sonnet 4.6 access is enabled."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Resource name prefix."
  type        = string
  default     = "vigil"
}

# --- DNS (subdomain delegated to Route 53) ---
variable "subdomain" {
  description = "Delegated subdomain hosted in Route 53, e.g. vigil.webtechhq.com."
  type        = string
  default     = "vigil.webtechhq.com"
}

variable "webhook_subdomain" {
  description = "soc-daemon webhook hostname; must be under var.subdomain."
  type        = string
  default     = "hooks.vigil.webtechhq.com"
}

# --- Container images / CI ---
variable "vigil_image_tag" {
  description = "Image tag pushed by CI — the pinned Vigil fork ref (e.g. v1.0.1-bedrock-deploy)."
  type        = string
  default     = "v1.0.1-bedrock-deploy"
}

variable "bifrost_image" {
  description = "Pinned Bifrost image."
  type        = string
  default     = "maximhq/bifrost:v1.5.16"
}

# --- GitHub OIDC (CI assumes this role; no static AWS keys in GitHub) ---
variable "github_owner" {
  description = "GitHub org/user that owns the deploy repo."
  type        = string
  default     = "jamessmoore"
}

variable "github_repo" {
  description = "Repo name CI runs from."
  type        = string
  default     = "vigil-bedrock-deploy"
}

# --- Bedrock targeting ---
variable "bedrock_sonnet_model_id" {
  description = "Bedrock model/inference-profile ID for Claude Sonnet 4.6 (e.g. us.anthropic.claude-sonnet-4-6-YYYYMMDD-v1:0). Confirm via `aws bedrock list-inference-profiles`."
  type        = string
}

variable "bedrock_invoke_resource_arns" {
  description = "Exact Bedrock ARNs the Bifrost task role may invoke (inference-profile ARN + underlying foundation-model ARNs). Never \"*\"."
  type        = list(string)
}

# --- Secrets (values supplied via gitignored terraform.tfvars, never committed) ---
variable "anthropic_api_key" {
  description = "Anthropic fallback-provider key."
  type        = string
  sensitive   = true
}

variable "openai_api_key" {
  description = "OpenAI fallback-provider key."
  type        = string
  sensitive   = true
}

# --- Sizing / cost toggles ---
variable "desired_count" {
  description = "Tasks per service."
  type        = number
  default     = 1
}

variable "rds_multi_az" {
  description = "Production HA toggle for RDS. Defaults false to keep this demo cost-conscious."
  type        = bool
  default     = false
}
