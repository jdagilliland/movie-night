# The single app instance and its data volume (SPEC §12).

# Ubuntu 24.04 LTS for ARM, looked up from Canonical's public parameter.
data "aws_ssm_parameter" "ubuntu_arm64" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id"
}

resource "aws_key_pair" "admin" {
  key_name   = "movie-night-admin"
  public_key = var.ssh_public_key
}

# The instance may pull images from ECR, and nothing else.
resource "aws_iam_role" "instance" {
  name = "movie-night-instance"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "instance_ecr_read" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "instance" {
  name = "movie-night-instance"
  role = aws_iam_role.instance.name
}

resource "aws_instance" "app" {
  ami                    = data.aws_ssm_parameter.ubuntu_arm64.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.app.id]
  key_name               = aws_key_pair.admin.key_name
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  # t4g instances default to "unlimited" credits, which bill for sustained
  # CPU above the baseline. "standard" throttles instead, so the bill can't
  # grow behind the budget's back.
  credit_specification {
    cpu_credits = "standard"
  }

  # Require IMDSv2 session tokens for the instance metadata service.
  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    # The data volume appears as an NVMe device whose by-id name contains
    # its volume ID without the dash.
    data_device    = "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${replace(aws_ebs_volume.data.id, "-", "")}"
    registry       = split("/", aws_ecr_repository.app.repository_url)[0]
    image          = "${aws_ecr_repository.app.repository_url}:latest"
    domain         = var.domain
    paste_ttl_days = var.paste_ttl_days
    compose_b64    = filebase64("${path.module}/../deploy/compose.yaml")
    caddyfile_b64  = filebase64("${path.module}/../deploy/Caddyfile")
    unit_b64       = filebase64("${path.module}/../deploy/movie-night.service")
  })

  # User data only runs at first boot. Ignoring changes to it (and to the
  # AMI, which Canonical updates regularly) keeps an apply from restarting
  # or replacing the running instance. To re-provision from scratch:
  #   tofu apply -replace=aws_instance.app
  lifecycle {
    ignore_changes = [ami, user_data]
  }

  # First-boot setup downloads packages immediately, so the instance must
  # not start before it has a route to the internet and outbound access.
  # (OpenTofu removes a new security group's default allow-all egress rule.)
  depends_on = [
    aws_route_table_association.public,
    aws_vpc_security_group_egress_rule.all,
  ]

  tags = { Name = "movie-night" }
}

# All persistent data lives here, apart from the instance (SPEC §12), so
# replacing the instance never touches it.
resource "aws_ebs_volume" "data" {
  availability_zone = var.availability_zone
  size              = var.data_volume_size_gb
  type              = "gp3"
  encrypted         = true

  tags = {
    Name = "movie-night-data"
    # Selects this volume for the daily snapshots (backups.tf).
    Snapshot = "movie-night"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.app.id

  # Detaching a mounted volume risks corrupting it; stop the instance first.
  stop_instance_before_detaching = true
}

# A fixed address, so the DNS record survives instance replacement.
resource "aws_eip" "app" {
  domain = "vpc"

  tags = { Name = "movie-night" }
}

resource "aws_eip_association" "app" {
  instance_id   = aws_instance.app.id
  allocation_id = aws_eip.app.id
}
