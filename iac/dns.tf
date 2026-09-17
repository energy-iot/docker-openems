# PR-C DNS + TLS for openems.eiot.energy.
#
# eiot.energy is registered at GoDaddy. We delegate the `openems` subdomain to
# a Route 53 hosted zone so ACM validation, the ALB alias, and cert renewal are
# all self-service in AWS. The ONLY manual step is a one-time NS record at
# GoDaddy (host "openems" -> the four name servers this zone emits; see the
# route53_name_servers output).
#
# Sequence:
#   1. apply with enable_tls=false  -> creates this zone + the ALB alias record.
#   2. add the NS record at GoDaddy; wait for `dig NS openems.eiot.energy @8.8.8.8`.
#   3. apply with enable_tls=true   -> ACM validates via DNS, HTTPS listeners come up.

# Hosted zone for the delegated subdomain.
resource "aws_route53_zone" "zone" {
  count = var.domain_name != "" ? 1 : 0
  name  = var.domain_name

  tags = {
    Name = "${var.project_name}-${var.environment}-zone"
  }
}

# openems.eiot.energy -> the ALB (ALIAS A-record, auto-tracks the ALB's IPs).
# Created as soon as the zone exists, so plain HTTP works right after delegation
# even before TLS is switched on.
resource "aws_route53_record" "alias" {
  count   = var.domain_name != "" ? 1 : 0
  zone_id = aws_route53_zone.zone[0].zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.alb.dns_name
    zone_id                = aws_lb.alb.zone_id
    evaluate_target_health = true
  }
}

# backend.openems.eiot.energy -> the same ALB. Edges connect here over wss:443;
# a listener rule (alb.tf) host-routes it to the Edge.Websocket target group.
resource "aws_route53_record" "backend_alias" {
  count   = var.domain_name != "" ? 1 : 0
  zone_id = aws_route53_zone.zone[0].zone_id
  name    = local.backend_host
  type    = "A"

  alias {
    name                   = aws_lb.alb.dns_name
    zone_id                = aws_lb.alb.zone_id
    evaluate_target_health = true
  }
}

# b2b.openems.eiot.energy -> the same ALB. MBE (Vercel) POSTs JSON-RPC here over
# https:443; a listener rule host-routes it to the Backend2Backend REST tg (8075).
resource "aws_route53_record" "b2b_alias" {
  count   = var.domain_name != "" ? 1 : 0
  zone_id = aws_route53_zone.zone[0].zone_id
  name    = local.b2b_host
  type    = "A"

  alias {
    name                   = aws_lb.alb.dns_name
    zone_id                = aws_lb.alb.zone_id
    evaluate_target_health = true
  }
}

# ---------------------------------------------------------------------------
# ACM certificate (DNS-validated) — only once TLS is being enabled.
# ---------------------------------------------------------------------------
resource "aws_acm_certificate" "cert" {
  count                     = var.enable_tls ? 1 : 0
  provider                  = aws.untagged # role lacks acm:AddTagsToCertificate
  domain_name               = var.domain_name
  subject_alternative_names = [local.backend_host, local.b2b_host]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# The DNS records ACM checks to prove we own each name (apex + backend). Keyed
# by domain_name, which is known at plan time, so this for_each is plan-safe.
resource "aws_route53_record" "cert_validation" {
  for_each = var.enable_tls ? {
    for dvo in aws_acm_certificate.cert[0].domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  zone_id         = aws_route53_zone.zone[0].zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

# Blocks until ACM sees the records above and issues the cert.
resource "aws_acm_certificate_validation" "cert" {
  count                   = var.enable_tls ? 1 : 0
  certificate_arn         = aws_acm_certificate.cert[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}
