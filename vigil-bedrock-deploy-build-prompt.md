# Build Prompt: vigil-bedrock-deploy

Paste this whole document into Claude Code at the root of a new, empty
directory to scaffold and build the repo.

---

## Context

I'm James Moore, a Senior SRE/DevOps Architect building an AI consulting
practice (Moore Solutions / WebTech HQ). I contribute to **Vigil**, an
open-source AI-powered Security Operations Center framework built by
DeepTempo, via my fork at `https://github.com/jamessmoore/vigil`. Vigil is a
FastAPI backend + React/MUI frontend (bundled into the backend image) +
PostgreSQL + Redis + a headless "soc-daemon" orchestrator process, with all
LLM traffic routed through **Bifrost** (`maximhq/bifrost`), a self-hosted
multi-provider LLM gateway, rather than calling any provider SDK directly.

I want you to build a **brand new, separate, self-contained repository**
called `vigil-bedrock-deploy`. Its job is to deploy Vigil to AWS using ECS
Fargate, with Bifrost configured to route primary LLM traffic through AWS
Bedrock (with Anthropic/OpenAI direct as configured fallback providers in
Bifrost, not removed). This repo does **not** vendor or fork Vigil's
application source — it builds Vigil's existing Docker images from a pinned
ref of my fork and deploys them. Do not modify, patch, or reinterpret any
Vigil application code (`backend/`, `daemon/`, `services/`, etc.) — this is
an infrastructure and deployment project only. The only Vigil-specific
artifact this repo owns is the Bifrost `config.json` (provider/routing
config), since that lives outside the app's Python source.

## Source facts to build from (already verified directly against the repo)

- Vigil's `docker/docker-compose.yml` defines the default (non-profile-gated)
  stack as exactly six services: `postgres`, `redis`, `backend`,
  `soc-daemon`, `llm-worker`, `bifrost`. Everything else in that file
  (`pgadmin`, `otel-collector`, `jaeger`, `prometheus`, `grafana`, `splunk`,
  `kafka`) is gated behind Compose `profiles:` and is **out of scope** for
  this deploy.
- `docker/Dockerfile.backend` is a 3-stage build (Node frontend build →
  Python deps → runtime). Final image runs
  `uvicorn backend.main:app --host 0.0.0.0 --port 6987` and serves the built
  React SPA itself via FastAPI `StaticFiles` — there is no separate frontend
  container or CDN to provision.
- `docker/Dockerfile.daemon` is a 2-stage build. Final image runs
  `python daemon/main.py` and exposes three ports: `8081` (webhook
  ingestion — needs to be internet-reachable for this deploy),
  `9090` (Prometheus metrics), `9091` (health/status).
- `llm-worker` reuses `Dockerfile.backend`'s image but overrides the command
  to `python -m services.run_llm_worker` — it's an ARQ worker consuming the
  Redis queue, no inbound ports at all.
- All four app services need `POSTGRES_*`, `REDIS_URL`, and `BIFROST_URL`
  env vars at minimum (see compose file for the full list per service —
  `soc-daemon` has many more, mostly optional integration credentials that
  can default to empty/disabled).
- `services/llm_clients.py` confirms all Anthropic-bound traffic in the app
  routes through `BIFROST_URL` + `/anthropic` passthrough already — no
  Vigil application code talks to a provider SDK directly except one
  documented exception (key-validation endpoints). This means making Vigil
  use Bedrock is a **Bifrost configuration change**, not an app code change.
- Bifrost (`maximhq/bifrost`) has native first-class AWS Bedrock provider
  support, including weighted routing / fallback between providers. Pull the
  current image from Docker Hub (`maximhq/bifrost:latest`, or pin a specific
  tag if one exists — check and prefer a pinned version over `:latest` for
  reproducibility).

## Two open questions to ask me before/while you scaffold

Ask me these directly — don't guess or stub around them:

1. **Domain / Route 53 hosted zone.** I need to give you the actual domain
   name and confirm whether the Route 53 hosted zone already exists in my
   AWS account or needs to be created by this Terraform. The plan is:
   `vigil.<mydomain>` → backend (default ALB rule), and
   `hooks.vigil.<mydomain>` → soc-daemon webhook (host-header ALB rule),
   both behind one ACM cert (wildcard `*.vigil.<mydomain>` plus the apex, or
   a SAN cert covering both names — your call on which is cleaner).
2. **Pinned ref of the Vigil fork to build from.** I need to give you the
   exact tag or commit SHA of `https://github.com/jamessmoore/vigil` this
   repo's CI should clone and build images from. Don't default to `main` or
   any other moving branch — ask me for a pinned ref and use that.

## Architecture to build

### Repo responsibilities
This repo owns: Terraform for all AWS infrastructure, a CI pipeline that
builds Vigil's two Docker images from the pinned fork ref and pushes them to
ECR, the Bifrost `config.json` for Bedrock + fallback provider routing, and
deployment docs. It does not own or modify any Vigil application code.

### AWS resource scope

**Networking**
- VPC, 2 public + 2 private subnets across 2 AZs, 1 NAT gateway (cost-
  optimized single NAT is fine — this is a portfolio/demo deploy, not a
  production HA requirement; note this as a one-line tradeoff in the README)
- Security groups, least-privilege, one per logical component: ALB, backend,
  soc-daemon, llm-worker, bifrost, RDS, ElastiCache. Each SG should only
  allow ingress from the specific SGs that legitimately call it — no broad
  "allow from VPC CIDR" shortcuts.

**DNS / TLS**
- ACM certificate covering both `vigil.<domain>` and `hooks.vigil.<domain>`,
  DNS-validated via Route 53
- Route 53 records for both hostnames as ALIAS records to the ALB
- (Exact hosted-zone handling depends on my answer to open question #1 above)

**Data layer**
- RDS PostgreSQL 16, single instance, `db.t4g.micro`, single-AZ (note
  Multi-AZ as a one-line toggle/variable for a "production" path, but don't
  default to it — cost-conscious for this deploy)
- ElastiCache for Redis, single node, `cache.t4g.micro`
- AWS Secrets Manager: DB master credentials (generated, not hardcoded),
  Anthropic API key, OpenAI API key (the two Bifrost fallback providers —
  values supplied via `terraform.tfvars`, gitignored, never committed)

**Compute (ECS Fargate)**
- One ECS cluster, Fargate only, no EC2 capacity provider
- Four services, each with its own task definition, task role, and
  CloudWatch log group:
  - `backend` — behind ALB, default listener rule
  - `soc-daemon` — behind ALB, host-header rule on `hooks.vigil.<domain>`,
    port 8081
  - `llm-worker` — no load balancer attachment, just runs and drains the
    Redis queue
  - `bifrost` — no public ALB attachment; reachable only from the other
    three services' security groups on port 8080
- Task execution role: shared across services, scoped to ECR pull +
  CloudWatch Logs write only
- Task roles: per-service, least-privilege. The `bifrost` task role is the
  one that matters most for the project's thesis — grant
  `bedrock:InvokeModel` and `bedrock:InvokeModelWithResponseStream`, scoped
  to specific Bedrock model ARNs (Claude Sonnet 4.6, not a wildcard
  `bedrock:*` or `resource: "*"`), plus `secretsmanager:GetSecretValue`
  scoped only to the Anthropic/OpenAI fallback-key secrets it needs to read
  at boot. Other services' task roles get only what they actually touch
  (most DB/Redis access is network-layer via SG, not IAM — don't over-grant
  IAM permissions services don't need).

**Load balancing**
- One ALB, public subnets
- HTTP (80) listener: redirect-to-HTTPS only
- HTTPS (443) listener: default rule → `backend` target group; host-header
  rule for `hooks.vigil.<domain>` → `soc-daemon` target group
- Health checks per target group matching each service's actual health
  endpoint (`backend` has `/api/health` per its Dockerfile HEALTHCHECK;
  `soc-daemon` has `/health` on port 9091 per its Dockerfile HEALTHCHECK —
  confirm the ALB target group health check path/port matches the
  *webhook* port 8081 behavior correctly, since that's the port actually
  behind this target group, not 9091)

**Container registry & CI**
- Two ECR repositories: `vigil-backend`, `vigil-daemon`
- GitHub Actions workflow using GitHub OIDC to assume an AWS IAM role
  (no long-lived AWS access keys stored as repo secrets) — mirror the
  pattern already proven in my `daily-tech-brief-bedrock` repo's CI
- CI pipeline: checkout the pinned Vigil fork ref (from open question #2)
  into a build context, build both images via Vigil's existing
  `docker/Dockerfile.backend` and `docker/Dockerfile.daemon` unmodified,
  tag with the pinned ref (not `latest`), push to ECR, then trigger
  `terraform apply` (or update the ECS services to the new task definition
  revision — your call on whether to do a full apply or a targeted service
  update, but document whichever you choose)

**Bifrost configuration**
- `bifrost/config.json` (or wherever Bifrost expects its seed config):
  configure AWS Bedrock as the primary provider for Claude Sonnet 4.6, with
  Anthropic direct and OpenAI as configured fallback providers using
  Bifrost's weighted-routing/fallback mechanism. Use the correct Bedrock
  model ID format (not the first-party Anthropic API model string). Do not
  hardcode any credentials into this file — Bedrock auth comes from the task
  role (no key needed), Anthropic/OpenAI keys come from the env vars Bifrost
  already expects (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`), sourced from
  Secrets Manager into the task definition, never from this file directly.

**Observability**
- Enable CloudWatch Container Insights on the ECS cluster
- One CloudWatch log group per service (already covered above) — no
  self-hosted Prometheus/Grafana/Jaeger for this deploy (those remain
  profile-gated and out of scope, consistent with the compose file)

### Repo structure (suggested — adjust if you have a better idiom for this)
```
vigil-bedrock-deploy/
├── terraform/
│   ├── modules/         # networking, data, ecs, alb, dns — your call on granularity
│   ├── environments/    # e.g. prod/ with its own backend config + tfvars
│   └── ...
├── bifrost/
│   └── config.json
├── .github/workflows/
│   ├── build-and-push.yml   # build Vigil images from pinned ref, push to ECR
│   └── deploy.yml           # terraform plan/apply via OIDC
├── README.md
└── .gitignore
```

## Constraints throughout

- No secrets committed anywhere, ever. `.env.example` / `terraform.tfvars.example`
  only. Real values via gitignored `terraform.tfvars` locally or CI secrets
  (OIDC role ARN, not static keys) in GitHub Actions.
- Every IAM policy should be scoped to specific resources/ARNs wherever
  AWS supports it. Flag in the README anywhere a wildcard resource was
  unavoidable and why.
- Single NAT gateway and single-AZ RDS/Redis are acceptable cost/complexity
  tradeoffs for this deploy — note them explicitly as tradeoffs in the
  README rather than silently under-building a "production" claim.
- Do not touch, fork, vendor, or reinterpret Vigil's application source.
  This repo's only Vigil-specific artifact is the Bifrost config.
- This is a portfolio-quality deliverable — code and Terraform should be
  clean, commented where non-obvious, and structured the way I'd want a
  technical reviewer (e.g. a senior platform engineer evaluating my AWS
  work) to read it.
- Once scaffolded, walk me through actually deploying it end-to-end:
  enabling Bedrock model access for Claude Sonnet 4.6 in the target region
  (one-time console/CLI step — document it explicitly), `terraform
  init/plan/apply`, confirming the CI pipeline builds and pushes images
  successfully, and a first manual verification that `backend` is reachable
  at `vigil.<domain>` and the `soc-daemon` webhook endpoint is reachable at
  `hooks.vigil.<domain>` before trusting either in production use.
