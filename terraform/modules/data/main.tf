# RDS PostgreSQL + ElastiCache Redis + Secrets Manager entries for the two
# Bifrost fallback-provider API keys.
#
# Tradeoff: both RDS and Redis are single-AZ / single-node, matching the
# compose file's "no HA" default profile. Acceptable for this portfolio/demo
# deploy. A production path would set rds_multi_az = true and add an
# ElastiCache replication group with a replica — both are one-line changes
# called out in variables, not modeled here to keep cost down.

resource "aws_db_subnet_group" "vigil" {
  name       = "${var.project_name}-rds"
  subnet_ids = var.private_subnet_ids
  tags       = var.tags
}

# manage_master_user_password = true makes RDS generate the master password
# itself and store it in a Secrets Manager secret it owns — no password is
# ever specified in Terraform config or state.
resource "aws_db_instance" "vigil" {
  identifier     = "${var.project_name}-postgres"
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  db_name                     = var.db_name
  username                    = var.db_username
  manage_master_user_password = true

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true
  multi_az          = var.multi_az

  db_subnet_group_name   = aws_db_subnet_group.vigil.name
  vpc_security_group_ids = [var.rds_security_group_id]

  backup_retention_period   = 1
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.project_name}-postgres-final"

  tags = var.tags
}

resource "aws_elasticache_subnet_group" "vigil" {
  name       = "${var.project_name}-redis"
  subnet_ids = var.private_subnet_ids
}

resource "aws_elasticache_cluster" "vigil" {
  cluster_id         = "${var.project_name}-redis"
  engine             = "redis"
  engine_version     = var.redis_engine_version
  node_type          = var.redis_node_type
  num_cache_nodes    = 1
  port               = 6379
  subnet_group_name  = aws_elasticache_subnet_group.vigil.name
  security_group_ids = [var.redis_security_group_id]

  tags = var.tags
}

resource "aws_secretsmanager_secret" "anthropic_api_key" {
  name = "${var.project_name}/bifrost/anthropic-api-key"
  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "anthropic_api_key" {
  secret_id     = aws_secretsmanager_secret.anthropic_api_key.id
  secret_string = var.anthropic_api_key
}

resource "aws_secretsmanager_secret" "openai_api_key" {
  name = "${var.project_name}/bifrost/openai-api-key"
  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "openai_api_key" {
  secret_id     = aws_secretsmanager_secret.openai_api_key.id
  secret_string = var.openai_api_key
}

# Backend JWT signing secret — generated, never supplied by hand. The backend
# requires JWT_SECRET_KEY when DEV_MODE=false.
resource "random_password" "jwt_secret" {
  length  = 64
  special = false
}

resource "aws_secretsmanager_secret" "jwt_secret" {
  name = "${var.project_name}/backend/jwt-secret-key"
  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "jwt_secret" {
  secret_id     = aws_secretsmanager_secret.jwt_secret.id
  secret_string = random_password.jwt_secret.result
}
