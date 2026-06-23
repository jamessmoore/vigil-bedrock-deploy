output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "alb_security_group_id" {
  value = aws_security_group.alb.id
}

output "backend_security_group_id" {
  value = aws_security_group.backend.id
}

output "soc_daemon_security_group_id" {
  value = aws_security_group.soc_daemon.id
}

output "llm_worker_security_group_id" {
  value = aws_security_group.llm_worker.id
}

output "bifrost_security_group_id" {
  value = aws_security_group.bifrost.id
}

output "rds_security_group_id" {
  value = aws_security_group.rds.id
}

output "redis_security_group_id" {
  value = aws_security_group.redis.id
}
