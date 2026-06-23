output "zone_id" {
  value = aws_route53_zone.vigil.zone_id
}

output "name_servers" {
  description = "Add these as an NS record for vigil.webtechhq.com at the external DNS host to delegate the subdomain."
  value       = aws_route53_zone.vigil.name_servers
}

output "certificate_arn" {
  value = aws_acm_certificate_validation.vigil.certificate_arn
}
