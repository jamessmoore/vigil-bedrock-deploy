resource "aws_ecs_cluster" "main" {
  name = var.project_name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = var.tags
}

# One CloudWatch log group per service.
resource "aws_cloudwatch_log_group" "backend" {
  name              = "/ecs/${var.project_name}/backend"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}
resource "aws_cloudwatch_log_group" "soc_daemon" {
  name              = "/ecs/${var.project_name}/soc-daemon"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}
resource "aws_cloudwatch_log_group" "llm_worker" {
  name              = "/ecs/${var.project_name}/llm-worker"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}
resource "aws_cloudwatch_log_group" "bifrost" {
  name              = "/ecs/${var.project_name}/bifrost"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

locals {
  # Render the Bifrost seed config from the committed template, substituting the
  # region and the Bedrock model ID. The result is written into a shared task
  # volume by an init container (below) so the stock Bifrost image stays
  # unmodified — no custom Bifrost image to build or maintain.
  bifrost_config_json = templatefile("${path.module}/../../../bifrost/config.json.tftpl", {
    aws_region              = var.aws_region
    bedrock_sonnet_model_id = var.bedrock_sonnet_model_id
  })

  # Plain (non-secret) env shared by the three app services. Postgres password
  # is injected separately via `secrets`, sourced from the RDS-managed secret.
  app_common_env = [
    { name = "POSTGRES_HOST", value = var.db_endpoint },
    { name = "POSTGRES_PORT", value = tostring(var.db_port) },
    { name = "POSTGRES_DB", value = var.db_name },
    { name = "POSTGRES_USER", value = var.db_username },
    { name = "REDIS_URL", value = "redis://${var.redis_endpoint}:${var.redis_port}/0" },
    { name = "BIFROST_URL", value = "http://bifrost.${var.project_name}.local:8080" },
    { name = "PYTHONUNBUFFERED", value = "1" },
  ]

  # POSTGRES_PASSWORD read from the `password` key of the RDS-managed secret JSON.
  db_password_secret = [
    { name = "POSTGRES_PASSWORD", valueFrom = "${var.db_master_secret_arn}:password::" },
  ]
}

# ---------------------------------------------------------------------------
# Service discovery — Bifrost has no ALB; the app services reach it by name
# (bifrost.<project>.local) over the private network on port 8080.
# ---------------------------------------------------------------------------
resource "aws_service_discovery_private_dns_namespace" "main" {
  name        = "${var.project_name}.local"
  description = "Internal service discovery for ${var.project_name}"
  vpc         = data.aws_subnet.first.vpc_id
  tags        = var.tags
}

data "aws_subnet" "first" {
  id = var.private_subnet_ids[0]
}

resource "aws_service_discovery_service" "bifrost" {
  name = "bifrost"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.main.id
    dns_records {
      type = "A"
      ttl  = 10
    }
    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Task definitions
# ---------------------------------------------------------------------------

# backend — FastAPI + bundled React SPA on 6987.
resource "aws_ecs_task_definition" "backend" {
  family                   = "${var.project_name}-backend"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.backend_task.arn

  # The backend writes to ./logs at startup, but it runs as the non-root
  # `vigil` user (uid 1000) and /app is root-owned, so the mkdir fails. The
  # Helm chart solves this with fsGroup:1000 on a mounted logs volume; Fargate
  # has no fsGroup, so a tiny root init container chowns an ephemeral volume to
  # 1000 before the backend mounts it at /app/logs — keeping the backend
  # non-root. (/app/data is already chowned to vigil in the image.)
  volume {
    name = "backend-logs"
  }

  container_definitions = jsonencode([
    {
      name      = "logs-init"
      image     = var.config_init_image
      essential = false
      command   = ["sh", "-c", "chown -R 1000:1000 /seedlogs"]
      mountPoints = [
        { sourceVolume = "backend-logs", containerPath = "/seedlogs", readOnly = false }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.backend.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "logs-init"
        }
      }
    },
    {
      name         = "backend"
      image        = var.backend_image
      essential    = true
      dependsOn    = [{ containerName = "logs-init", condition = "SUCCESS" }]
      portMappings = [{ containerPort = 6987, protocol = "tcp" }]
      mountPoints = [
        { sourceVolume = "backend-logs", containerPath = "/app/logs", readOnly = false }
      ]
      # DEV_MODE=false runs the backend in production mode, which requires a
      # JWT signing key (injected from Secrets Manager).
      environment = concat(local.app_common_env, [
        { name = "DEV_MODE", value = "false" },
      ])
      secrets = concat(local.db_password_secret, [
        { name = "JWT_SECRET_KEY", valueFrom = var.jwt_secret_arn },
      ])
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.backend.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "backend"
        }
      }
    }
  ])

  tags = var.tags
}

# soc-daemon — webhook 8081 (LB-facing), metrics 9090, health 9091.
resource "aws_ecs_task_definition" "soc_daemon" {
  family                   = "${var.project_name}-soc-daemon"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.soc_daemon_task.arn

  container_definitions = jsonencode([
    {
      name      = "soc-daemon"
      image     = var.daemon_image
      essential = true
      portMappings = [
        { containerPort = 8081, protocol = "tcp" },
        { containerPort = 9090, protocol = "tcp" },
        { containerPort = 9091, protocol = "tcp" },
      ]
      # soc-daemon has many optional integration credentials (Splunk,
      # CrowdStrike, Slack, etc.); they default to empty/disabled and are
      # intentionally omitted here. Add them as `secrets` when wiring an
      # integration. Only the always-on DB/Redis/Bifrost wiring is set.
      environment = concat(local.app_common_env, [
        { name = "DAEMON_WEBHOOK_ENABLED", value = "true" },
        { name = "DAEMON_WEBHOOK_PORT", value = "8081" },
        { name = "DAEMON_HEALTH_PORT", value = "9091" },
        { name = "DAEMON_METRICS_ENABLED", value = "true" },
      ])
      secrets = local.db_password_secret
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.soc_daemon.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "soc-daemon"
        }
      }
    }
  ])

  tags = var.tags
}

# llm-worker — reuses the backend image, overrides command to the ARQ worker.
resource "aws_ecs_task_definition" "llm_worker" {
  family                   = "${var.project_name}-llm-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.llm_worker_task.arn

  container_definitions = jsonencode([
    {
      name        = "llm-worker"
      image       = var.backend_image
      essential   = true
      command     = ["python", "-m", "services.run_llm_worker"]
      environment = local.app_common_env
      secrets     = local.db_password_secret
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.llm_worker.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "llm-worker"
        }
      }
    }
  ])

  tags = var.tags
}

# bifrost — stock image + an init container that seeds config.json into a
# shared ephemeral volume. Bedrock auth is the task role (no key); the
# Anthropic/OpenAI fallback keys are injected from Secrets Manager.
resource "aws_ecs_task_definition" "bifrost" {
  family                   = "${var.project_name}-bifrost"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.bifrost_task.arn

  volume {
    name = "bifrost-config"
  }

  container_definitions = jsonencode([
    {
      name      = "bifrost-config-init"
      image     = var.config_init_image
      essential = false
      # Config has no secrets, so passing it via env + writing it to the shared
      # volume is safe. The real Bedrock credentials are the task role; the
      # fallback API keys live in Secrets Manager and never touch this file.
      environment = [
        { name = "BIFROST_CONFIG_JSON", value = local.bifrost_config_json },
      ]
      command = ["sh", "-c", "printf '%s' \"$BIFROST_CONFIG_JSON\" > /seed/config.json"]
      mountPoints = [
        { sourceVolume = "bifrost-config", containerPath = "/seed", readOnly = false }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.bifrost.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "config-init"
        }
      }
    },
    {
      name         = "bifrost"
      image        = var.bifrost_image
      essential    = true
      dependsOn    = [{ containerName = "bifrost-config-init", condition = "SUCCESS" }]
      portMappings = [{ containerPort = 8080, protocol = "tcp" }]
      environment = [
        { name = "AWS_REGION", value = var.aws_region },
      ]
      # Bedrock needs no key (task role). Anthropic/OpenAI fallback keys come
      # from Secrets Manager into the env vars Bifrost already expects.
      secrets = [
        { name = "ANTHROPIC_API_KEY", valueFrom = var.anthropic_secret_arn },
        { name = "OPENAI_API_KEY", valueFrom = var.openai_secret_arn },
      ]
      mountPoints = [
        { sourceVolume = "bifrost-config", containerPath = "/app/data", readOnly = false }
      ]
      healthCheck = {
        command     = ["CMD-SHELL", "wget -qO- http://localhost:8080/health | grep -q '\"status\":\"ok\"'"]
        interval    = 15
        timeout     = 5
        retries     = 5
        startPeriod = 20
      }
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.bifrost.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "bifrost"
        }
      }
    }
  ])

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Services
# ---------------------------------------------------------------------------
resource "aws_ecs_service" "backend" {
  name            = "backend"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.backend.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.backend_security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.backend_target_group_arn
    container_name   = "backend"
    container_port   = 6987
  }

  tags = var.tags
}

resource "aws_ecs_service" "soc_daemon" {
  name            = "soc-daemon"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.soc_daemon.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.soc_daemon_security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.soc_daemon_target_group_arn
    container_name   = "soc-daemon"
    container_port   = 8081
  }

  tags = var.tags
}

resource "aws_ecs_service" "llm_worker" {
  name            = "llm-worker"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.llm_worker.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.llm_worker_security_group_id]
    assign_public_ip = false
  }

  tags = var.tags
}

resource "aws_ecs_service" "bifrost" {
  name            = "bifrost"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.bifrost.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.bifrost_security_group_id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.bifrost.arn
  }

  tags = var.tags
}
