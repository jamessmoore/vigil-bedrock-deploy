output "alb_dns_name" {
  value = aws_lb.main.dns_name
}

output "alb_zone_id" {
  value = aws_lb.main.zone_id
}

output "alb_arn" {
  value = aws_lb.main.arn
}

output "backend_target_group_arn" {
  value = aws_lb_target_group.backend.arn
}

output "soc_daemon_target_group_arn" {
  value = aws_lb_target_group.soc_daemon.arn
}

output "https_listener_arn" {
  value = aws_lb_listener.https.arn
}
