locals {
  tags = {
    Project   = var.project_name
    ManagedBy = "terraform"
    Repo      = "${var.github_owner}/${var.github_repo}"
  }
}

# ---------------------------------------------------------------------------
# Container registry (ECR) for the two Vigil images built by CI.
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "backend" {
  name                 = "vigil-backend"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
  tags = local.tags
}

resource "aws_ecr_repository" "daemon" {
  name                 = "vigil-daemon"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
  tags = local.tags
}

# ---------------------------------------------------------------------------
# GitHub OIDC — lets CI assume an AWS role with no long-lived access keys.
# The provider is account-wide and shared across repos (CoreSample,
# daily-tech-brief-bedrock, etc. already created it), so we reference the
# existing one rather than creating a second — IAM allows only one OIDC
# provider per URL per account.
# ---------------------------------------------------------------------------
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "github_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_owner}/${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "${var.project_name}-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_assume.json
  tags               = local.tags
}

# CI needs to push to ECR and update ECS services. Scoped to this deploy's
# repos/cluster where the API supports resource-level scoping; ECR auth-token
# and a few describe calls are inherently account-wide (flagged in README).
data "aws_iam_policy_document" "github_actions" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "EcrPushPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [
      aws_ecr_repository.backend.arn,
      aws_ecr_repository.daemon.arn,
    ]
  }
  statement {
    sid = "EcsDeploy"
    actions = [
      "ecs:UpdateService",
      "ecs:DescribeServices",
      "ecs:RegisterTaskDefinition",
      "ecs:DescribeTaskDefinition",
    ]
    resources = ["*"]
  }
  statement {
    sid     = "PassTaskRoles"
    actions = ["iam:PassRole"]
    resources = [
      module.ecs.bifrost_task_role_arn,
    ]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "github_actions" {
  name   = "${var.project_name}-github-actions"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions.json
}

# ---------------------------------------------------------------------------
# Modules
# ---------------------------------------------------------------------------
module "networking" {
  source       = "../../modules/networking"
  project_name = var.project_name
  tags         = local.tags
}

module "data" {
  source                  = "../../modules/data"
  project_name            = var.project_name
  private_subnet_ids      = module.networking.private_subnet_ids
  rds_security_group_id   = module.networking.rds_security_group_id
  redis_security_group_id = module.networking.redis_security_group_id
  multi_az                = var.rds_multi_az
  anthropic_api_key       = var.anthropic_api_key
  openai_api_key          = var.openai_api_key
  tags                    = local.tags
}

module "alb" {
  source                = "../../modules/alb"
  project_name          = var.project_name
  vpc_id                = module.networking.vpc_id
  public_subnet_ids     = module.networking.public_subnet_ids
  alb_security_group_id = module.networking.alb_security_group_id
  certificate_arn       = module.dns.certificate_arn
  webhook_subdomain     = var.webhook_subdomain
  tags                  = local.tags
}

module "dns" {
  source            = "../../modules/dns"
  subdomain         = var.subdomain
  webhook_subdomain = var.webhook_subdomain
  tags              = local.tags
}

# ALIAS records live here (not in the dns module) to break the dns<->alb cycle:
# the dns module feeds the cert to alb, and these records need alb's DNS name.
resource "aws_route53_record" "backend" {
  zone_id = module.dns.zone_id
  name    = var.subdomain
  type    = "A"
  alias {
    name                   = module.alb.alb_dns_name
    zone_id                = module.alb.alb_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "webhook" {
  zone_id = module.dns.zone_id
  name    = var.webhook_subdomain
  type    = "A"
  alias {
    name                   = module.alb.alb_dns_name
    zone_id                = module.alb.alb_zone_id
    evaluate_target_health = true
  }
}

module "ecs" {
  source       = "../../modules/ecs"
  project_name = var.project_name
  aws_region   = var.aws_region

  private_subnet_ids = module.networking.private_subnet_ids

  backend_security_group_id    = module.networking.backend_security_group_id
  soc_daemon_security_group_id = module.networking.soc_daemon_security_group_id
  llm_worker_security_group_id = module.networking.llm_worker_security_group_id
  bifrost_security_group_id    = module.networking.bifrost_security_group_id

  backend_target_group_arn    = module.alb.backend_target_group_arn
  soc_daemon_target_group_arn = module.alb.soc_daemon_target_group_arn

  backend_image = "${aws_ecr_repository.backend.repository_url}:${var.vigil_image_tag}"
  daemon_image  = "${aws_ecr_repository.daemon.repository_url}:${var.vigil_image_tag}"
  bifrost_image = var.bifrost_image

  db_endpoint          = module.data.db_endpoint
  db_port              = module.data.db_port
  db_name              = module.data.db_name
  db_username          = module.data.db_username
  db_master_secret_arn = module.data.db_master_secret_arn
  redis_endpoint       = module.data.redis_endpoint
  redis_port           = module.data.redis_port

  anthropic_secret_arn = module.data.anthropic_secret_arn
  openai_secret_arn    = module.data.openai_secret_arn

  bedrock_sonnet_model_id      = var.bedrock_sonnet_model_id
  bedrock_invoke_resource_arns = var.bedrock_invoke_resource_arns

  desired_count = var.desired_count
  tags          = local.tags
}
