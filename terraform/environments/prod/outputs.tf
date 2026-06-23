output "route53_name_servers" {
  description = "Add these as an NS record for the delegated subdomain at your external DNS host (one-time step)."
  value       = module.dns.name_servers
}

output "alb_dns_name" {
  description = "ALB DNS name (both hostnames alias to this)."
  value       = module.alb.alb_dns_name
}

output "backend_url" {
  value = "https://${var.subdomain}"
}

output "webhook_url" {
  value = "https://${var.webhook_subdomain}"
}

output "ecr_backend_repository_url" {
  value = aws_ecr_repository.backend.repository_url
}

output "ecr_daemon_repository_url" {
  value = aws_ecr_repository.daemon.repository_url
}

output "github_actions_role_arn" {
  description = "Set as the AWS_ROLE_ARN secret/var in GitHub Actions."
  value       = aws_iam_role.github_actions.arn
}

output "ecs_cluster_name" {
  value = module.ecs.cluster_name
}

output "ecs_service_names" {
  value = module.ecs.service_names
}

output "db_master_secret_arn" {
  description = "Secrets Manager ARN of the RDS-managed master credentials (for running DB init/migrations)."
  value       = module.data.db_master_secret_arn
}
