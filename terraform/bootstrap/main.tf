locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = "aws"
  role_arn   = "arn:${local.partition}:iam::${local.account_id}:role/${var.project_name}-*"
  oidc_arn   = "arn:${local.partition}:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com"
  secret_arn = "arn:${local.partition}:secretsmanager:${var.aws_region}:${local.account_id}:secret:${var.project_name}/*"
  rds_secret = "arn:${local.partition}:secretsmanager:${var.aws_region}:${local.account_id}:secret:rds!*"
  bucket_arn = "arn:${local.partition}:s3:::${var.state_bucket_name}"
  tags = {
    Project   = var.project_name
    ManagedBy = "terraform-bootstrap"
    Purpose   = "deployer-identity-and-state"
  }
}

# ---------------------------------------------------------------------------
# Terraform remote-state bucket for the MAIN stack.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket_name
  tags   = local.tags
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# Deployer IAM user.
# ---------------------------------------------------------------------------
resource "aws_iam_user" "deployer" {
  name = var.deployer_user_name
  tags = local.tags
}

resource "aws_iam_access_key" "deployer" {
  count = var.create_access_key ? 1 : 0
  user  = aws_iam_user.deployer.name
}

# ---------------------------------------------------------------------------
# Policy 1 — infrastructure services the main stack provisions.
# EC2 is a curated action list (no ec2:*); the other single-purpose services
# use service-level wildcards for create/modify/delete/describe/tag, which is
# the practical least-privilege granularity for a stack that fully owns them.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "infra" {
  statement {
    sid    = "Ec2Networking"
    effect = "Allow"
    actions = [
      # All EC2 reads (DescribeAddressesAttribute, etc.) — read-only, so a
      # wildcard here is low-risk; write actions below stay explicit.
      "ec2:Describe*",
      "ec2:CreateVpc", "ec2:DeleteVpc", "ec2:ModifyVpcAttribute",
      "ec2:DescribeVpcs", "ec2:DescribeVpcAttribute",
      "ec2:CreateSubnet", "ec2:DeleteSubnet", "ec2:ModifySubnetAttribute", "ec2:DescribeSubnets",
      "ec2:CreateInternetGateway", "ec2:DeleteInternetGateway",
      "ec2:AttachInternetGateway", "ec2:DetachInternetGateway", "ec2:DescribeInternetGateways",
      "ec2:CreateNatGateway", "ec2:DeleteNatGateway", "ec2:DescribeNatGateways",
      "ec2:AllocateAddress", "ec2:ReleaseAddress", "ec2:DescribeAddresses",
      "ec2:CreateRouteTable", "ec2:DeleteRouteTable", "ec2:CreateRoute", "ec2:DeleteRoute",
      "ec2:AssociateRouteTable", "ec2:DisassociateRouteTable", "ec2:DescribeRouteTables",
      "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup",
      "ec2:DescribeSecurityGroups", "ec2:DescribeSecurityGroupRules",
      "ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress",
      "ec2:ModifySecurityGroupRules",
      "ec2:UpdateSecurityGroupRuleDescriptionsIngress",
      "ec2:UpdateSecurityGroupRuleDescriptionsEgress",
      "ec2:CreateTags", "ec2:DeleteTags", "ec2:DescribeTags",
      "ec2:DescribeAvailabilityZones", "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeAccountAttributes",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ManagedServices"
    effect = "Allow"
    actions = [
      "elasticloadbalancing:*",
      "ecs:*",
      "rds:*",
      "elasticache:*",
      "ecr:*",
      "logs:*",
      "servicediscovery:*",
      "route53:*",
      "acm:*",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "infra" {
  name        = "${var.project_name}-deployer-infra"
  description = "Infrastructure-service permissions for deploying the Vigil stack."
  policy      = data.aws_iam_policy_document.infra.json
  tags        = local.tags
}

# ---------------------------------------------------------------------------
# Policy 2 — IAM, Secrets Manager, and Terraform state. The blast-radius-
# sensitive grants, scoped tightly: IAM role/OIDC actions are limited to
# vigil-* role names and the GitHub OIDC provider; Secrets Manager to the
# project's secret prefix; S3 to the state bucket only.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "iam_state" {
  statement {
    sid    = "ManageVigilRoles"
    effect = "Allow"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole",
      "iam:TagRole", "iam:UntagRole", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
      "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy",
      "iam:UpdateAssumeRolePolicy",
    ]
    resources = [local.role_arn]
  }

  statement {
    sid       = "PassVigilTaskRoles"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [local.role_arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  statement {
    sid    = "ManageGithubOidcProvider"
    effect = "Allow"
    actions = [
      "iam:CreateOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider",
      "iam:GetOpenIDConnectProvider", "iam:TagOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint",
    ]
    resources = [local.oidc_arn]
  }

  # ListOpenIDConnectProviders has no resource-level scoping; the data source
  # that resolves the shared GitHub provider by URL needs it.
  statement {
    sid       = "ListOidcProviders"
    effect    = "Allow"
    actions   = ["iam:ListOpenIDConnectProviders"]
    resources = ["*"]
  }

  # ECS/RDS/ElastiCache may need their service-linked roles to exist; allow
  # creating them only for those services (no-op if already present).
  statement {
    sid       = "CreateServiceLinkedRoles"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values = [
        "ecs.amazonaws.com",
        "rds.amazonaws.com",
        "elasticache.amazonaws.com",
      ]
    }
  }

  statement {
    sid    = "ManageProjectSecrets"
    effect = "Allow"
    actions = [
      "secretsmanager:CreateSecret", "secretsmanager:DeleteSecret",
      "secretsmanager:DescribeSecret", "secretsmanager:GetSecretValue",
      "secretsmanager:PutSecretValue", "secretsmanager:TagResource",
      "secretsmanager:UntagResource", "secretsmanager:GetResourcePolicy",
      "secretsmanager:ListSecretVersionIds",
    ]
    resources = [local.secret_arn, local.rds_secret]
  }

  # GetRandomPassword takes no resource.
  statement {
    sid       = "SecretsRandomPassword"
    effect    = "Allow"
    actions   = ["secretsmanager:GetRandomPassword"]
    resources = ["*"]
  }

  # RDS storage encryption + managed master password require the creating
  # principal to grant/describe the KMS keys RDS and Secrets Manager use.
  # Scoped via kms:ViaService to those two services only.
  statement {
    sid    = "KmsForRdsAndSecrets"
    effect = "Allow"
    actions = [
      "kms:DescribeKey", "kms:CreateGrant", "kms:RetireGrant",
      "kms:Decrypt", "kms:GenerateDataKey", "kms:GenerateDataKeyWithoutPlaintext",
      "kms:ReEncryptFrom", "kms:ReEncryptTo",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values = [
        "rds.${var.aws_region}.amazonaws.com",
        "secretsmanager.${var.aws_region}.amazonaws.com",
      ]
    }
  }

  statement {
    sid    = "TerraformStateBucket"
    effect = "Allow"
    actions = [
      "s3:ListBucket", "s3:GetBucketLocation", "s3:GetBucketVersioning",
    ]
    resources = [local.bucket_arn]
  }

  statement {
    sid    = "TerraformStateObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
    ]
    resources = ["${local.bucket_arn}/*"]
  }
}

resource "aws_iam_policy" "iam_state" {
  name        = "${var.project_name}-deployer-iam-secrets-state"
  description = "IAM (vigil-* scoped), Secrets Manager (project prefix), and state-bucket permissions for the Vigil deployer."
  policy      = data.aws_iam_policy_document.iam_state.json
  tags        = local.tags
}

resource "aws_iam_user_policy_attachment" "infra" {
  user       = aws_iam_user.deployer.name
  policy_arn = aws_iam_policy.infra.arn
}

resource "aws_iam_user_policy_attachment" "iam_state" {
  user       = aws_iam_user.deployer.name
  policy_arn = aws_iam_policy.iam_state.arn
}
