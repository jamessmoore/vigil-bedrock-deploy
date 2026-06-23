# VPC, 2 public + 2 private subnets across 2 AZs, single NAT gateway,
# and all least-privilege security groups for the Vigil deploy.
#
# Tradeoff: a single NAT gateway is a single point of failure for private
# subnet egress (e.g. ECR pulls, CloudWatch, Secrets Manager, Bedrock/Bifrost
# fallback-provider calls) if its AZ has an outage. Acceptable for this
# portfolio/demo deploy; a production path would add one NAT per AZ.

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = "${var.project_name}-vpc" })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, { Name = "${var.project_name}-igw" })
}

resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, { Name = "${var.project_name}-public-${local.azs[count.index]}" })
}

resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, { Name = "${var.project_name}-private-${local.azs[count.index]}" })
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.project_name}-nat-eip" })
}

# Single NAT gateway in the first public subnet — see tradeoff note above.
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = merge(var.tags, { Name = "${var.project_name}-nat" })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(var.tags, { Name = "${var.project_name}-public-rt" })
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = merge(var.tags, { Name = "${var.project_name}-private-rt" })
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ---------------------------------------------------------------------------
# Security groups — one per logical component. Each only accepts ingress
# from the specific SGs that legitimately call it; no "allow from VPC CIDR"
# shortcuts. Rules are declared as standalone aws_vpc_security_group_*_rule
# resources rather than inline blocks, so each rule is independently
# readable/auditable.
# ---------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb"
  description = "Public ALB: vigil.<domain> and hooks.vigil.<domain>"
  vpc_id      = aws_vpc.main.id
  tags        = merge(var.tags, { Name = "${var.project_name}-alb-sg" })
}

resource "aws_security_group" "backend" {
  name        = "${var.project_name}-backend"
  description = "Vigil backend (FastAPI + bundled React SPA), port 6987"
  vpc_id      = aws_vpc.main.id
  tags        = merge(var.tags, { Name = "${var.project_name}-backend-sg" })
}

resource "aws_security_group" "soc_daemon" {
  name        = "${var.project_name}-soc-daemon"
  description = "Vigil soc-daemon: webhook 8081, health 9091"
  vpc_id      = aws_vpc.main.id
  tags        = merge(var.tags, { Name = "${var.project_name}-soc-daemon-sg" })
}

resource "aws_security_group" "llm_worker" {
  name        = "${var.project_name}-llm-worker"
  description = "Vigil llm-worker (ARQ worker, no inbound ports)"
  vpc_id      = aws_vpc.main.id
  tags        = merge(var.tags, { Name = "${var.project_name}-llm-worker-sg" })
}

resource "aws_security_group" "bifrost" {
  name        = "${var.project_name}-bifrost"
  description = "Bifrost LLM gateway, port 8080, reachable only from app services"
  vpc_id      = aws_vpc.main.id
  tags        = merge(var.tags, { Name = "${var.project_name}-bifrost-sg" })
}

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds"
  description = "RDS PostgreSQL, port 5432"
  vpc_id      = aws_vpc.main.id
  tags        = merge(var.tags, { Name = "${var.project_name}-rds-sg" })
}

resource "aws_security_group" "redis" {
  name        = "${var.project_name}-redis"
  description = "ElastiCache Redis, port 6379"
  vpc_id      = aws_vpc.main.id
  tags        = merge(var.tags, { Name = "${var.project_name}-redis-sg" })
}

# --- ALB ---------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "Public HTTP (redirected to HTTPS by the listener)"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "Public HTTPS"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_backend" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward to backend target group"
  referenced_security_group_id = aws_security_group.backend.id
  from_port                    = 6987
  to_port                      = 6987
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_soc_daemon_webhook" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward to soc-daemon webhook target group"
  referenced_security_group_id = aws_security_group.soc_daemon.id
  from_port                    = 8081
  to_port                      = 8081
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_soc_daemon_health" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Target group health check override port"
  referenced_security_group_id = aws_security_group.soc_daemon.id
  from_port                    = 9091
  to_port                      = 9091
  ip_protocol                  = "tcp"
}

# --- backend -------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "backend_from_alb" {
  security_group_id            = aws_security_group.backend.id
  description                  = "ALB -> backend"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 6987
  to_port                      = 6987
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "backend_to_rds" {
  security_group_id            = aws_security_group.backend.id
  referenced_security_group_id = aws_security_group.rds.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "backend_to_redis" {
  security_group_id            = aws_security_group.backend.id
  referenced_security_group_id = aws_security_group.redis.id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "backend_to_bifrost" {
  security_group_id            = aws_security_group.backend.id
  referenced_security_group_id = aws_security_group.bifrost.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "backend_https_egress" {
  security_group_id = aws_security_group.backend.id
  description       = "ECR pull / CloudWatch Logs / Secrets Manager via NAT (no VPC endpoints in this deploy)"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# --- soc-daemon ------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "soc_daemon_webhook_from_alb" {
  security_group_id            = aws_security_group.soc_daemon.id
  description                  = "ALB -> soc-daemon webhook ingestion"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 8081
  to_port                      = 8081
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "soc_daemon_health_from_alb" {
  security_group_id            = aws_security_group.soc_daemon.id
  description                  = "ALB target group health check override port (9091), distinct from the 8081 traffic port"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 9091
  to_port                      = 9091
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "soc_daemon_to_rds" {
  security_group_id            = aws_security_group.soc_daemon.id
  referenced_security_group_id = aws_security_group.rds.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "soc_daemon_to_redis" {
  security_group_id            = aws_security_group.soc_daemon.id
  referenced_security_group_id = aws_security_group.redis.id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "soc_daemon_to_bifrost" {
  security_group_id            = aws_security_group.soc_daemon.id
  referenced_security_group_id = aws_security_group.bifrost.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "soc_daemon_https_egress" {
  security_group_id = aws_security_group.soc_daemon.id
  description       = "ECR pull / CloudWatch Logs / Secrets Manager via NAT"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# --- llm-worker -----------------------------------------------------------
# No ingress rules at all: this service has no inbound ports.

resource "aws_vpc_security_group_egress_rule" "llm_worker_to_rds" {
  security_group_id            = aws_security_group.llm_worker.id
  referenced_security_group_id = aws_security_group.rds.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "llm_worker_to_redis" {
  security_group_id            = aws_security_group.llm_worker.id
  referenced_security_group_id = aws_security_group.redis.id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "llm_worker_to_bifrost" {
  security_group_id            = aws_security_group.llm_worker.id
  referenced_security_group_id = aws_security_group.bifrost.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "llm_worker_https_egress" {
  security_group_id = aws_security_group.llm_worker.id
  description       = "ECR pull / CloudWatch Logs / Secrets Manager via NAT"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# --- bifrost ----------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "bifrost_from_backend" {
  security_group_id            = aws_security_group.bifrost.id
  referenced_security_group_id = aws_security_group.backend.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "bifrost_from_soc_daemon" {
  security_group_id            = aws_security_group.bifrost.id
  referenced_security_group_id = aws_security_group.soc_daemon.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "bifrost_from_llm_worker" {
  security_group_id            = aws_security_group.bifrost.id
  referenced_security_group_id = aws_security_group.llm_worker.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "bifrost_https_egress" {
  security_group_id = aws_security_group.bifrost.id
  description       = "Bedrock API, Anthropic/OpenAI fallback providers, ECR pull, CloudWatch Logs, Secrets Manager"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# --- rds / redis: no egress needed, they never initiate connections -------

resource "aws_vpc_security_group_ingress_rule" "rds_from_backend" {
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = aws_security_group.backend.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_soc_daemon" {
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = aws_security_group.soc_daemon.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_llm_worker" {
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = aws_security_group.llm_worker.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "redis_from_backend" {
  security_group_id            = aws_security_group.redis.id
  referenced_security_group_id = aws_security_group.backend.id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "redis_from_soc_daemon" {
  security_group_id            = aws_security_group.redis.id
  referenced_security_group_id = aws_security_group.soc_daemon.id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "redis_from_llm_worker" {
  security_group_id            = aws_security_group.redis.id
  referenced_security_group_id = aws_security_group.llm_worker.id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
}
