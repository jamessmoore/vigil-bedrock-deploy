data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# ---------------------------------------------------------------------------
# Task execution role — shared across all four services.
# ECS uses this role (not the task role) to pull images and to read the
# Secrets Manager secrets that get injected as container env vars at boot.
# Scoped to ECR pull, CloudWatch Logs write, and GetSecretValue on exactly
# the three secrets this deploy injects — no wildcards.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "execution" {
  name               = "${var.project_name}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = var.tags
}

# AmazonECSTaskExecutionRolePolicy covers ECR pull + CloudWatch Logs. It is an
# AWS-managed policy whose ECR/logs actions are inherently resource "*"
# (documented as a wildcard exception in the README).
resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "execution_secrets" {
  statement {
    sid     = "ReadInjectedSecrets"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      var.db_master_secret_arn,
      var.anthropic_secret_arn,
      var.openai_secret_arn,
      var.jwt_secret_arn,
    ]
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "${var.project_name}-execution-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets.json
}

# ---------------------------------------------------------------------------
# Per-service task roles. Most data-plane access (Postgres, Redis) is granted
# at the network layer via security groups, not IAM — so the backend,
# soc-daemon, and llm-worker task roles carry no inline permissions. They
# exist so each service runs under its own identity (clean CloudTrail, easy to
# extend later) rather than sharing one over-broad role.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "backend_task" {
  name               = "${var.project_name}-backend-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = var.tags
}

resource "aws_iam_role" "soc_daemon_task" {
  name               = "${var.project_name}-soc-daemon-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = var.tags
}

resource "aws_iam_role" "llm_worker_task" {
  name               = "${var.project_name}-llm-worker-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = var.tags
}

# ---------------------------------------------------------------------------
# Bifrost task role — the one that matters for the project's thesis.
# Bedrock auth is SigV4 via this role (no API key), scoped to specific model
# ARNs. InvokeModel + InvokeModelWithResponseStream only; no bedrock:* and no
# resource "*".
# ---------------------------------------------------------------------------
resource "aws_iam_role" "bifrost_task" {
  name               = "${var.project_name}-bifrost-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "bifrost_bedrock" {
  statement {
    sid = "InvokeScopedBedrockModels"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = var.bedrock_invoke_resource_arns
  }
}

resource "aws_iam_role_policy" "bifrost_bedrock" {
  name   = "${var.project_name}-bifrost-bedrock"
  role   = aws_iam_role.bifrost_task.id
  policy = data.aws_iam_policy_document.bifrost_bedrock.json
}
