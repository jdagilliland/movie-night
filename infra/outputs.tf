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

output "ssh_command" {
  value = "ssh ubuntu@${aws_eip.app.public_ip}"
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "github_actions_role_arn" {
  description = "Set this as the AWS_ROLE_ARN variable in the GitHub repository."
  value       = aws_iam_role.github_actions.arn
}
