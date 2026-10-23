# Optional DNS (SPEC §12): with route53_zone_name set, the A record for the
# domain is managed here; without it, DNS is managed elsewhere and nothing
# below is created. The domain itself is registered by hand, not here, so
# no apply or destroy can affect the registration.

data "aws_route53_zone" "app" {
  count = var.route53_zone_name == null ? 0 : 1

  name         = var.route53_zone_name
  private_zone = false
}

resource "aws_route53_record" "app" {
  count = var.route53_zone_name == null ? 0 : 1

  zone_id = data.aws_route53_zone.app[0].zone_id
  name    = var.domain
  type    = "A"
  ttl     = 300
  records = [aws_eip.app.public_ip]

  lifecycle {
    precondition {
      condition = (
        var.domain == trimsuffix(var.route53_zone_name, ".")
        || endswith(var.domain, ".${trimsuffix(var.route53_zone_name, ".")}")
      )
      error_message = "The domain must be the zone itself or a name within it."
    }
  }
}
