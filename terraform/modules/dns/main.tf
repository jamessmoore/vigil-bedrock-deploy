# This zone is a delegated subdomain, not an apex domain — webtechhq.com
# itself stays at the external DNS host. After the first apply, take the
# name_servers output and add ONE NS record at the external host:
#   vigil.webtechhq.com  NS  <the 4 values from the name_servers output>
# That one manual step hands authority for everything under
# vigil.webtechhq.com (including hooks.vigil.webtechhq.com) to this zone.
# Terraform manages everything else — ACM validation records and the ALIAS
# records below — with no further manual DNS console work.

resource "aws_route53_zone" "vigil" {
  name = var.subdomain
  tags = merge(var.tags, { Name = var.subdomain })
}

# SAN certificate covering both hostnames explicitly, rather than a wildcard
# (*.vigil.webtechhq.com). A SAN cert scoped to exactly the two names in use
# is tighter than a wildcard that would also validate for any future/unused
# subdomain — least-privilege applied to certs, not just IAM.
resource "aws_acm_certificate" "vigil" {
  domain_name               = var.subdomain
  subject_alternative_names = [var.webhook_subdomain]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = var.tags
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.vigil.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = aws_route53_zone.vigil.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "vigil" {
  certificate_arn         = aws_acm_certificate.vigil.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# The ALIAS records pointing both hostnames at the ALB are NOT created here.
# This module's certificate_arn output feeds the alb module (HTTPS listener
# needs the cert), and the ALIAS records need the alb module's DNS name —
# wiring both directions into one module would create a module-level cycle.
# The two ALIAS records are created in the root module instead, once both
# this module's zone_id and the alb module's outputs are available.
