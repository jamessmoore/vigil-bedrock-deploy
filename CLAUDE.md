# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project

`vigil-bedrock-deploy` is infrastructure-as-code that deploys
[**Vigil**](https://github.com/jamessmoore/vigil) — an open-source AI-powered
Security Operations Center framework — to AWS on **ECS Fargate**, with all LLM
traffic routed through a self-hosted [**Bifrost**](https://github.com/maximhq/bifrost)
gateway configured so the **primary provider is Amazon Bedrock** (Claude
Sonnet 4.6), with **Anthropic direct** and **OpenAI** as configured fallbacks.

The thesis: making Vigil run on Bedrock is a **Bifrost configuration change, not
an application change** — Vigil already routes all Anthropic-bound traffic
through `BIFROST_URL`, so pointing Bifrost at Bedrock is enough. See `README.md`
for the full architecture and deploy walkthrough.

This repo is **infrastructure and deployment only**. It does **not** vendor,
fork, patch, or reinterpret any Vigil application code (`backend/`, `daemon/`,
`services/`, etc.) — it builds Vigil's existing Docker images from a **pinned
ref** of the fork and deploys them. The only Vigil-specific artifact this repo
owns is the Bifrost provider/routing config (`bifrost/config.json.tftpl`), which
lives outside Vigil's Python source.

## Current status — read before assuming anything is stale

Terraform is scaffolded and **validates clean** (`terraform validate` →
Success; ~45 resources across 5 modules). **No real deploy has been run yet** —
the AWS resources do not exist, and the following remain to be supplied before a
first `apply`:

- The pinned Vigil fork tag (`v1.0.0-bedrock-deploy`) must be created/pushed on
  the fork before CI can build images from it.
- `bedrock_sonnet_model_id` and `bedrock_invoke_resource_arns` must be filled
  with the **real** Bedrock inference-profile ID + ARNs for the target region —
  do not trust a guessed dated suffix. Confirm with
  `aws bedrock list-inference-profiles`.
- Bedrock Claude Sonnet 4.6 model access must be enabled in the region (one-time
  console/CLI step).
- The `/anthropic` passthrough → Bedrock routing must be verified post-deploy
  (see `bifrost/README.md`) — the governance routing rule is the intended
  mechanism, but whether the passthrough surface honors it needs confirmation in
  Bifrost's `core` routing-engine logs.

Terraform remote state lives in S3 (`terraform/environments/prod/versions.tf`'s
`backend "s3"` block, native locking via `use_lockfile`) — not local state, so
`terraform plan`/`apply` need real AWS credentials and the state bucket. CI
authenticates via GitHub OIDC (no static AWS keys); `terraform output
github_actions_role_arn` is the role CI assumes.

## Required workflow — no direct commits to master

`master` is protected: no direct pushes, no force-pushes, no branch deletion,
and no bypass — applies even to repo admins. A PR with a passing `test` status
check (`.github/workflows/test.yml`) is required before merge.

1. Create a new branch off `master` for the change (e.g. `git checkout -b fix/short-description`).
2. Commit changes to that branch.
3. Push the branch and open a pull request targeting `master` (`gh pr create`).
4. Wait for the `test` status check to pass on the PR.
5. Merge the PR into `master` only after CI passes (`gh pr merge --merge --delete-branch`).
6. The repo has `delete_branch_on_merge` enabled, so the **remote** branch is
   deleted automatically on merge. After merging, switch back to `master`, pull,
   then clean up the **local** copy:
   `git checkout master && git pull && git fetch --prune && git branch -d <branch>`.

Never commit directly to `master` and never push directly to `master`.

## Local verification before opening/updating a PR

This mirrors `.github/workflows/test.yml` — if these pass locally, the `test`
status check will pass.

```bash
# Formatting across all Terraform
terraform fmt -check -recursive terraform

# Validate the root module (provider download only; no backend, no AWS creds)
cd terraform/environments/prod
terraform init -backend=false
terraform validate
```

Keep this section and `.github/workflows/test.yml` in sync if either changes.

## Project structure

```
terraform/
  modules/
    networking/   VPC, 2 public + 2 private subnets / 2 AZs, single NAT,
                  per-component least-privilege security groups (ALB, backend,
                  soc-daemon, llm-worker, bifrost, RDS, Redis). SG-to-SG rules
                  only — no VPC-CIDR shortcuts.
    dns/          Route 53 hosted zone for the DELEGATED subdomain
                  (vigil.<domain>), SAN ACM cert (apex + hooks), DNS validation.
                  ALIAS records live in the root module to break the dns<->alb
                  cycle.
    data/         RDS PostgreSQL 16 (t4g.micro, RDS-managed master password),
                  ElastiCache Redis (t4g.micro), Secrets Manager for the two
                  Bifrost fallback keys. DB name/user default to the app's
                  compose values so Vigil's database/init/ scripts run unchanged.
    alb/          Public ALB, HTTP->HTTPS redirect, HTTPS default rule -> backend,
                  host-header rule -> soc-daemon webhook (port 8081 traffic,
                  port 9091 health check).
    ecs/          ECS cluster (Container Insights), 4 Fargate services (backend,
                  soc-daemon, llm-worker, bifrost), per-service log groups, shared
                  execution role, per-service task roles. Bifrost task role gets
                  scoped bedrock:InvokeModel* on specific ARNs only. Stock Bifrost
                  image + a config-init sidecar that seeds config.json into a
                  shared volume (no custom image to build).
  environments/
    prod/         Root module wiring all child modules, ECR repos, GitHub OIDC
                  provider/role, S3 backend, variables/outputs, tfvars example.
bifrost/
  config.json.tftpl  Bedrock-primary routing config (Terraform template).
  README.md          Model-ID lookup + /anthropic passthrough verification note.
.github/workflows/
  test.yml           CI gate: terraform fmt + validate, on every PR/push to master.
  build-and-push.yml Build Vigil images from the pinned fork ref -> ECR (OIDC).
  deploy.yml         terraform apply + force ECS redeploy (OIDC).
```

## License & contributors

MIT License (`LICENSE`). `CONTRIBUTING.md` and `CONTRIBUTORS.md` document that
this is a solo project by James Moore with Claude (Anthropic) as an AI
development collaborator with no commit access or independent decision-making
authority.

## Commit messages

Short, imperative, capitalized summary line. No conventional-commit prefixes
(`feat:`, `fix:`, etc.) — matches the convention used in `CoreSample`,
`daily-tech-brief-bedrock`, and `aws-audit-mcp`.

## Notes

- This repo is a portfolio/interview proof-of-concept (see the user's global
  CLAUDE.md, section 9) — keep README and commit history client-presentable.
- The exact Bedrock model identifier is intentionally **parameterized**, not
  hardcoded: Bifrost uses the legacy Bedrock Converse path with dated
  inference-profile IDs that can't be verified without the target account.
  Never invent a dated suffix — look it up.
- When unsure of an AWS provider resource's exact schema, check the installed
  provider's real schema first (`terraform providers schema -json`) rather than
  guessing from docs or blog posts.
