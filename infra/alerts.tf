# Email alerts when the app is down, for any reason.

resource "aws_sns_topic" "alerts" {
  name = "movie-night-alerts"
}

# AWS emails a confirmation link to this address; alerts flow only after
# it is clicked.
resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Probes the public URL from several AWS regions, so it catches a stopped
# instance, a crashed container, a bad certificate, and broken DNS alike.
# /healthz returns 200 only when the database is reachable (SPEC NFR-12).
# Three probe regions (the minimum) keep the request log quiet; the
# default of about 15 means roughly 30 requests a minute.
resource "aws_route53_health_check" "app" {
  type              = "HTTPS"
  fqdn              = var.domain
  port              = 443
  resource_path     = "/healthz"
  request_interval  = 30
  failure_threshold = 3
  enable_sni        = true
  regions           = ["us-east-1", "us-west-2", "eu-west-1"]

  tags = { Name = "movie-night" }
}

# Route 53 health check metrics exist only in us-east-1, so this alarm
# must be created there (the default region).
resource "aws_cloudwatch_metric_alarm" "app_down" {
  alarm_name          = "movie-night-app-down"
  alarm_description   = "https://${var.domain}/healthz is failing."
  namespace           = "AWS/Route53"
  metric_name         = "HealthCheckStatus"
  dimensions          = { HealthCheckId = aws_route53_health_check.app.id }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# Distinguishes "the machine is unhealthy" from "the app is unhealthy".
resource "aws_cloudwatch_metric_alarm" "instance_status" {
  alarm_name          = "movie-night-instance-status"
  alarm_description   = "EC2 status checks are failing."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  dimensions          = { InstanceId = aws_instance.app.id }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "breaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}
