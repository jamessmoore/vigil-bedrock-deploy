# vigil-bedrock-deploy

Infrastructure-as-code to deploy [**Vigil**](https://github.com/jamessmoore/vigil)
— an open-source, AI-powered Security Operations Center framework — to AWS on
**ECS Fargate**, with all LLM traffic routed through a self-hosted
[**Bifrost**](https://github.com/maximhq/bifrost) gateway configured so the
**primary provider is Amazon Bedrock** (Claude Sonnet 4.6), with **Anthropic
direct** and **OpenAI** as configured fallbacks.

This repository is **infrastructure and deployment only**. It does not vendor,
fork, patch, or reinterpret any Vigil application code. It builds Vigil's
existing Docker images from a **pinned ref** of the fork and deploys them. The
single Vigil-specific artifact it owns is the Bifrost provider/routing config
(`bifrost/config.json.tftpl`), which lives outside Vigil's Python source.

The thesis: making Vigil run on Bedrock is a **Bifrost configuration change, not
an application change** — Vigil already routes all Anthropic-bound traffic
through `BIFROST_URL`, so pointing Bifrost at Bedrock is enough.

---

## Architecture

```
                          Route 53 (delegated subdomain: vigil.webtechhq.com)
                                   │
                          ┌────────┴────────┐
                          │   ALB (public)  │  HTTP→HTTPS, ACM SAN cert
                          └────────┬────────┘
              default rule │                 │ host-header rule
        vigil.webtechhq.com│                 │hooks.vigil.webtechhq.com
                          ▼                 ▼
                   ┌────────────┐     ┌────────────┐
                   │  backend   │     │ soc-daemon │   (Fargate, private subnets)
                   │  :6987     │     │  :8081 hook│
                   └─────┬──────┘     └─────┬──────┘
                         │   ┌──────────────┘
                         ▼   ▼
                   ┌────────────┐     ┌────────────┐
                   │  bifrost   │◄────│ llm-worker │   (no ALB; internal only)
                   │  :8080     │     └─────┬──────┘
                   └─────┬──────┘           │
       Bedrock (SigV4,   │                  │
       task role)  ──────┤            ┌─────┴─────┐
       Anthropic/OpenAI  │            ▼           ▼
       (fallback keys)   │      ┌─────────┐ ┌──────────┐
                         └─────▶│   RDS   │ │ElastiCache│
                                │Postgres │ │  Redis   │
                                └─────────┘ └──────────┘
```

Four ECS services map 1:1 to Vigil's default (non-profile-gated) compose stack:

| Service      | Image                         | Ports                | LB                                  |
| ------------ | ----------------------------- | -------------------- | ----------------------------------- |
| `backend`    | `Dockerfile.backend`          | 6987                 | ALB default rule                    |
| `soc-daemon` | `Dockerfile.daemon`           | 8081 / 9090 / 9091   | ALB host-header rule (webhook 8081) |
| `llm-worker` | `Dockerfile.backend` (override `python -m services.run_llm_worker`) | none | none |
| `bifrost`    | `maximhq/bifrost` (stock)     | 8080                 | internal (service discovery)        |

Out of scope (profile-gated in Vigil's compose): pgadmin, otel-collector,
jaeger, prometheus, grafana, splunk, kafka.

### Repository layout

```
vigil-bedrock-deploy/
├── terraform/
│   ├── modules/{networking,dns,data,alb,ecs}/
│   └── environments/prod/        # root module + tfvars
├── bifrost/
│   ├── config.json.tftpl         # provider + Bedrock-primary routing config
│   └── README.md
├── .github/workflows/
│   ├── build-and-push.yml        # build Vigil images from pinned ref → ECR
│   └── deploy.yml                # terraform apply + force ECS redeploy (OIDC)
└── README.md
```

---

## Accepted tradeoffs (this is a portfolio/demo deploy, not production HA)

- **Single NAT gateway** — one NAT for both private subnets. Cheaper, but a
  single point of failure for private-subnet egress if its AZ fails. Production
  path: one NAT per AZ.
- **Single-AZ RDS** — `db.t4g.micro`, single instance. Flip `rds_multi_az = true`
  for the production path (one-line toggle).
- **Single-node ElastiCache** — `cache.t4g.micro`, no replica.
- **`desired_count = 1`** per service — no horizontal redundancy by default.

### Where a wildcard resource was unavoidable (flagged per the constraints)

- `ecr:GetAuthorizationToken` — AWS only supports `resource: "*"` for this
  action; the actual push/pull is scoped to the two repo ARNs.
- `ecs:UpdateService` / `RegisterTaskDefinition` / `DescribeServices` /
  `DescribeTaskDefinition` (CI role) — these don't support resource-level
  scoping in a way that fits a per-deploy role cleanly; left as `*`.
- `AmazonECSTaskExecutionRolePolicy` (managed) — its ECR/CloudWatch-Logs actions
  are inherently `*`. Everything custom (Secrets Manager, Bedrock) is ARN-scoped.

### One intentional deviation from the build prompt

The prompt suggested putting `secretsmanager:GetSecretValue` on the **Bifrost
task role**. ECS-native secret injection is performed by the **execution role**,
not the task role — so the scoped `GetSecretValue` (DB master + Anthropic +
OpenAI secrets) lives on the shared execution role, and the Bifrost **task**
role carries only the scoped Bedrock `InvokeModel*` permissions it actually uses
at runtime. This is the more correct least-privilege split: Bifrost reads its
fallback keys from env (injected at boot), it never calls Secrets Manager
itself.

---

## Prerequisites

- Terraform >= 1.10 (uses S3 native state locking, `use_lockfile`)
- AWS CLI v2, authenticated to the target account
- A registered domain whose DNS you control (here: `webtechhq.com`), hosted at
  an external provider — you'll delegate a subdomain to Route 53
- An S3 bucket for Terraform remote state

---

## Deploy walkthrough (end-to-end)

### 0. Pin the Vigil fork ref

Create and push the tag this deploy builds from (don't use a moving branch):

```bash
# in your jamessmoore/vigil fork
git tag -a v1.0.1-bedrock-deploy -m "Pinned ref for vigil-bedrock-deploy" <commit-sha>
git push origin v1.0.1-bedrock-deploy
```

### 1. Enable Bedrock model access (one-time, per region)

Bedrock foundation models are **opt-in per account/region**. Until you enable
Claude Sonnet 4.6, every `InvokeModel` returns `AccessDeniedException`.

- Console: **Bedrock → Model access → Manage model access →** enable **Anthropic
  Claude Sonnet 4.6 →** Save. Wait until status is **Access granted**.
- Then capture the exact model identifier (don't guess the dated suffix):

```bash
aws bedrock list-inference-profiles --region us-east-1 \
  --query "inferenceProfileSummaries[?contains(inferenceProfileName,'Sonnet 4.6')]"
```

Use the returned inference-profile ID for `bedrock_sonnet_model_id`, and build
`bedrock_invoke_resource_arns` from its ARN plus the underlying foundation-model
ARNs in each region the profile routes to.

### 2. Configure variables

```bash
cd terraform/environments/prod
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: domain, Bedrock model ID + ARNs, fallback API keys
```

`terraform.tfvars` is gitignored — real secrets never get committed.

### 3. Configure remote state and apply

```bash
terraform init \
  -backend-config="bucket=YOUR_TF_STATE_BUCKET" \
  -backend-config="key=vigil-bedrock-deploy/prod/terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="encrypt=true" \
  -backend-config="use_lockfile=true"

terraform plan
terraform apply
```

### 4. Delegate the subdomain (one-time manual DNS step)

Terraform creates a Route 53 hosted zone for `vigil.webtechhq.com`. Grab its
nameservers and add **one NS record** at your external DNS host:

```bash
terraform output route53_name_servers
```

At your registrar/DNS host, create:
`vigil.webtechhq.com  NS  → (the 4 AWS nameservers)`

Once propagated, Route 53 has authority over everything under
`vigil.webtechhq.com` (including `hooks.vigil.webtechhq.com` and ACM DNS
validation). The ACM cert validation and ALIAS records then complete
automatically — no further DNS console work. If `apply` was still waiting on
ACM validation, re-run `terraform apply` after delegation propagates.

### 5. Wire up CI (GitHub OIDC — no static AWS keys)

```bash
terraform output github_actions_role_arn
```

In the GitHub repo settings:

- **Secrets:** `AWS_ROLE_ARN` (above), `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`
- **Variables:** `TF_STATE_BUCKET`, `BEDROCK_SONNET_MODEL_ID`,
  `BEDROCK_INVOKE_RESOURCE_ARNS` (JSON array string)

### 6. Build & push images, then deploy

- Run the **build-and-push** workflow (manual dispatch, default ref
  `v1.0.1-bedrock-deploy`). It clones the pinned fork ref, builds both images
  from Vigil's unmodified Dockerfiles, and pushes them to ECR tagged with the
  ref.
- Run the **deploy** workflow. It applies Terraform and forces a rolling
  redeploy of all four services onto the new images.

### 7. Initialize the database (one-time)

RDS does **not** run Vigil's `database/init/` scripts (those only run in the
compose Postgres container). Run them once against RDS — e.g. via a one-off task
in the VPC, or a bastion/port-forward — using the RDS-managed credentials:

```bash
terraform output db_master_secret_arn   # fetch username/password from this secret
```

### 8. Verify before trusting it

```bash
# backend reachable + healthy
curl -fsS https://vigil.webtechhq.com/api/health

# soc-daemon webhook endpoint reachable (host-header routed to port 8081)
curl -fsS -X POST https://hooks.vigil.webtechhq.com/  # expect the daemon's webhook response
```

**Confirm Bedrock is actually serving Claude traffic** — this is the whole
point. Trigger any LLM-backed action in Vigil, then check Bifrost's logs (the
`core` routing-engine trail) and CloudWatch for the `bifrost` service to confirm
requests are served by `bedrock`, not falling through to Anthropic/OpenAI. See
[`bifrost/README.md`](bifrost/README.md) for the `/anthropic` passthrough caveat
and how to fix routing if the passthrough bypasses governance in your Bifrost
version.

---

## Teardown

```bash
cd terraform/environments/prod
terraform destroy
```

Then remove the `vigil.webtechhq.com` NS record at your external DNS host.
