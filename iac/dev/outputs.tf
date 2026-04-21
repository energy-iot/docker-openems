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

output "b2b_url_direct" {
  description = "OpenEMS B2B REST endpoint — direct public IP access (for debugging; keep allowed_ips locked down)"
  value       = "http://${aws_instance.openems.public_ip}:8082"
}

output "b2b_url_lambda" {
  description = "OpenEMS B2B REST endpoint via Lambda VPC proxy (HTTPS + IAM SigV4)"
  value       = aws_lambda_function_url.proxy.function_url
}

output "lambda_invoker_access_key_id" {
  description = "Access key ID for the MBE invoker IAM user (set as OPENEMS_AWS_ACCESS_KEY_ID in Vercel)"
  value       = aws_iam_access_key.mbe_invoker.id
}

output "lambda_invoker_secret_key" {
  description = "Secret access key for the MBE invoker IAM user (set as OPENEMS_AWS_SECRET_ACCESS_KEY in Vercel)"
  value       = aws_iam_access_key.mbe_invoker.secret
  sensitive   = true
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
