output "db_endpoint" {
  value = aws_db_instance.vigil.address
}

output "db_port" {
  value = aws_db_instance.vigil.port
}

output "db_name" {
  value = aws_db_instance.vigil.db_name
}

output "db_username" {
  value = aws_db_instance.vigil.username
}

output "db_master_secret_arn" {
  description = "Secrets Manager secret ARN holding the RDS-generated master credentials (JSON: username/password)."
  value       = aws_db_instance.vigil.master_user_secret[0].secret_arn
}

output "redis_endpoint" {
  value = aws_elasticache_cluster.vigil.cache_nodes[0].address
}

output "redis_port" {
  value = aws_elasticache_cluster.vigil.cache_nodes[0].port
}

output "anthropic_secret_arn" {
  value = aws_secretsmanager_secret.anthropic_api_key.arn
}

output "openai_secret_arn" {
  value = aws_secretsmanager_secret.openai_api_key.arn
}

output "jwt_secret_arn" {
  value = aws_secretsmanager_secret.jwt_secret.arn
}
