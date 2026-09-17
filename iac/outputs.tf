# PR-C ingress outputs.

# The four name servers to paste into GoDaddy as an NS record for host
# "openems" under eiot.energy. This is the one-time manual delegation step.
output "route53_name_servers" {
  description = "Add these as an NS record (host: openems) in GoDaddy's eiot.energy DNS."
  value       = var.domain_name != "" ? aws_route53_zone.zone[0].name_servers : []
}

# The ALB's AWS-assigned name. Resolves publicly with no DNS setup — use it to
# test routing over HTTP before the delegation is live.
output "alb_dns_name" {
  description = "ALB default hostname (*.elb.amazonaws.com), for pre-DNS testing."
  value       = aws_lb.alb.dns_name
}

# The public UI URL once TLS is on.
output "openems_url" {
  description = "Public UI URL after delegation + enable_tls."
  value       = var.domain_name != "" ? "https://${var.domain_name}" : "http://${aws_lb.alb.dns_name}"
}

# What edges/Pis point their Controller.Api.Backend at.
output "edge_websocket_url" {
  description = "wss URL for field edges (once enable_tls). Set ctrlBackend0.config uri to this."
  value       = var.enable_tls ? "wss://${local.backend_host}" : "ws://${aws_lb.alb.dns_name}:8081"
}
