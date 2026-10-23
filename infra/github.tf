# GitHub Actions pushes images to ECR using short-lived credentials from
# GitHub's OIDC provider, so no AWS keys are stored in GitHub (SPEC §12).

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  github_owner = split("/", var.github_repository)[0]
  github_name  = split("/", var.github_repository)[1]

  # GitHub identifies the repository by name and immutable ID, e.g.
  # repo:OWNER@OWNER_ID/NAME@REPO_ID:ref:refs/heads/main. The IDs mean a
  # different repository that later takes the same name can't assume the
  # role.
  github_main_subject = "repo:${local.github_owner}@${var.github_owner_id}/${local.github_name}@${var.github_repository_id}:ref:refs/heads/main"
}

resource "aws_iam_role" "github_actions" {
  name = "movie-night-github-actions"

  # Only workflows running on the main branch of this repository.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = local.github_main_subject
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions_push" {
  name = "push-movie-night-image"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Logging in to ECR isn't scoped to a repository.
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
        ]
        Resource = aws_ecr_repository.app.arn
      },
    ]
  })
}
