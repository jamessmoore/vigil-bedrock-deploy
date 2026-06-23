variable "project_name" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "rds_security_group_id" {
  type = string
}

variable "redis_security_group_id" {
  type = string
}

# Defaults match Vigil's docker-compose.yml (POSTGRES_DB=deeptempo_soc,
# POSTGRES_USER=deeptempo) so the app's database/init/ scripts run against RDS
# unmodified. The app reads both from env vars, so these can be changed — but
# keep them consistent with whatever the init scripts expect.
variable "db_name" {
  description = "PostgreSQL database name (no hyphens — Postgres identifier rules)."
  type        = string
  default     = "deeptempo_soc"
}

variable "db_username" {
  type    = string
  default = "deeptempo"
}

variable "db_engine_version" {
  description = "Confirm the latest available 16.x minor via `aws rds describe-db-engine-versions --engine postgres --query \"DBEngineVersions[?starts_with(EngineVersion,'16.')].EngineVersion\"` before first apply — minor versions are periodically deprecated by AWS."
  type        = string
  default     = "16.10"
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "redis_engine_version" {
  type    = string
  default = "7.1"
}

variable "redis_node_type" {
  type    = string
  default = "cache.t4g.micro"
}

variable "multi_az" {
  description = "Multi-AZ RDS for the production path. Defaults false (cost-conscious demo)."
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "true is convenient for a portfolio/demo deploy you expect to tear down; set false for anything you'd call production."
  type        = bool
  default     = true
}

variable "anthropic_api_key" {
  description = "Fallback provider key for Bifrost. Supply via terraform.tfvars (gitignored) or CI secret — never commit."
  type        = string
  sensitive   = true
}

variable "openai_api_key" {
  description = "Fallback provider key for Bifrost. Supply via terraform.tfvars (gitignored) or CI secret — never commit."
  type        = string
  sensitive   = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
