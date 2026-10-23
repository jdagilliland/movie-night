locals {
  # Flags for aws CLI commands printed below, matching this configuration.
  aws_cli_flags = join(" ", compact([
    var.aws_profile == null ? "" : "--profile ${var.aws_profile}",
    "--region ${var.region}",
  ]))
}

output "public_ip" {
  description = "Without route53_zone_name, point the domain's DNS A record here."
  value       = aws_eip.app.public_ip
}

output "dns" {
  value = (
    var.route53_zone_name == null
    ? "Not managed here: point ${var.domain} at ${aws_eip.app.public_ip}"
    : "Managed in Route 53 zone ${var.route53_zone_name}"
  )
}

output "instance_id" {
  value = aws_instance.app.id
}

output "session_command" {
  description = "A shell on the instance via Session Manager (needs session-manager-plugin)."
  value       = "aws ssm start-session --target ${aws_instance.app.id} ${local.aws_cli_flags}"
}

output "ssh_config" {
  description = "A ~/.ssh/config entry for ssh and scp through Session Manager. The instance ID changes when the instance is replaced."
  value       = <<-EOT
    Host movie-night
      HostName ${aws_instance.app.id}
      User ubuntu
      IdentityFile ~/.ssh/movie-night
      ProxyCommand aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters portNumber=22 ${local.aws_cli_flags}
  EOT
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "github_actions_role_arn" {
  description = "Set this as the AWS_ROLE_ARN variable in the GitHub repository."
  value       = aws_iam_role.github_actions.arn
}
