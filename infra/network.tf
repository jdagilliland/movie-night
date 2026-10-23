# A minimal VPC: one public subnet and an internet gateway. No NAT gateway,
# which would cost more than everything else combined.

resource "aws_vpc" "main" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "movie-night" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "movie-night" }
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.42.1.0/24"
  availability_zone = var.availability_zone

  tags = { Name = "movie-night-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "movie-night-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "app" {
  name        = "movie-night"
  description = "Movie Night: HTTP(S) from anywhere, SSH from admins"
  vpc_id      = aws_vpc.main.id
}

# Rule descriptions may not contain apostrophes (EC2 rejects them at apply
# time; validate doesn't catch it).
resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.app.id
  description       = "HTTP (Caddy redirects to HTTPS; Lets Encrypt challenges)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_ingress_rule" "http3" {
  security_group_id = aws_security_group.app.id
  description       = "HTTP/3 (QUIC)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  # One rule per admin CIDR and SSH port, keyed "CIDR port".
  for_each = {
    for pair in setproduct(var.admin_cidrs, var.ssh_ports) :
    "${pair[0]} ${pair[1]}" => { cidr = pair[0], port = pair[1] }
  }

  security_group_id = aws_security_group.app.id
  description       = "SSH from an admin"
  cidr_ipv4         = each.value.cidr
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.app.id
  description       = "All outbound (packages, ECR, Lets Encrypt)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
