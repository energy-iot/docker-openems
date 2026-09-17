output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.openems.id
}

output "public_ip" {
  description = "Public IP of the EC2 instance"
  value       = aws_instance.openems.public_ip
}

output "ui_url" {
  description = "OpenEMS UI URL"
  value       = "http://${aws_instance.openems.public_ip}:4200"
}

output "b2b_url" {
  description = "OpenEMS B2B REST endpoint (for MBE)"
  value       = "http://${aws_instance.openems.public_ip}:8082"
}

output "odoo_url" {
  description = "Odoo admin URL"
  value       = "http://${aws_instance.openems.public_ip}:10016"
}

output "ssm_connect_command" {
  description = "Connect to the instance via SSM Session Manager"
  value       = "aws ssm start-session --target ${aws_instance.openems.id} --region ${var.region}"
}

output "bootstrap_log_tail" {
  description = "Tail the bootstrap log via SSM"
  value       = "aws ssm start-session --target ${aws_instance.openems.id} --region ${var.region} --document-name AWS-StartInteractiveCommand --parameters command='sudo tail -f /var/log/openems-bootstrap.log'"
}
