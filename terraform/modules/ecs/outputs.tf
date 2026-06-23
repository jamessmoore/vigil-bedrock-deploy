output "cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "cluster_arn" {
  value = aws_ecs_cluster.main.arn
}

output "service_names" {
  value = {
    backend    = aws_ecs_service.backend.name
    soc_daemon = aws_ecs_service.soc_daemon.name
    llm_worker = aws_ecs_service.llm_worker.name
    bifrost    = aws_ecs_service.bifrost.name
  }
}

output "bifrost_task_role_arn" {
  value = aws_iam_role.bifrost_task.arn
}
