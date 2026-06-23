# Bootstrap — deployer identity & state bucket

A **one-time, admin-run** Terraform config that provisions everything the main
stack needs *before* it can be deployed by a non-admin:

- the S3 **state bucket** for the main stack (versioned, encrypted, public
  access blocked);
- a dedicated **`vigil-deployer` IAM user**;
- two scoped customer-managed policies attached to it:
  - `vigil-deployer-infra` — EC2 (curated network actions), plus
    elasticloadbalancing / ecs / rds / elasticache / ecr / logs /
    servicediscovery / route53 / acm;
  - `vigil-deployer-iam-secrets-state` — IAM **scoped to `vigil-*` roles** and
    the GitHub OIDC provider, Secrets Manager **scoped to `vigil/*`** (+ RDS
    managed secrets), and S3 **scoped to the state bucket**.

This separates the powerful, IAM-creating bootstrap (run once, by an admin)
from the day-to-day deploys (run as `vigil-deployer`, which cannot create
arbitrary IAM, only `vigil-*` roles).

## Why local state

This config creates the very bucket the main stack uses as its backend, so it
can't store its own state there. It uses **local state** by design. The
resulting `terraform.tfstate` contains the deployer's **secret access key** —
keep it out of version control (it is gitignored) and treat it as a secret, or
set `create_access_key = false` and mint the key out-of-band instead.

## Run it (once, with admin credentials)

```bash
cd terraform/bootstrap
terraform init
terraform apply     # review: 1 bucket (+3 bucket settings), 1 user, 2 policies, 2 attachments, 1 access key

# Capture the deployer credentials
terraform output deployer_access_key_id
terraform output -raw deployer_secret_access_key
terraform output -raw state_bucket_name
```

Store the credentials as a named AWS profile:

```bash
aws configure --profile vigil-deployer   # paste the key id + secret, region us-west-2
```

If you prefer not to keep the secret in state, set `create_access_key = false`
and mint it yourself after apply:

```bash
aws iam create-access-key --user-name vigil-deployer
```

## Then deploy the main stack as the deployer

```bash
cd ../environments/prod
AWS_PROFILE=vigil-deployer terraform init \
  -backend-config="bucket=$(terraform -chdir=../bootstrap output -raw state_bucket_name)" \
  -backend-config="key=vigil-bedrock-deploy/prod/terraform.tfstate" \
  -backend-config="region=us-west-2" \
  -backend-config="encrypt=true" \
  -backend-config="use_lockfile=true"

AWS_PROFILE=vigil-deployer terraform apply
```

## Notes / scope

- The `vigil-deployer-infra` policy uses **service-level wildcards** for the
  single-purpose services the stack fully owns (ELB, ECS, RDS, etc.). EC2 is a
  curated action list rather than `ec2:*`, since EC2 is a shared namespace.
- A principal that can create IAM roles can in principle escalate privilege;
  that risk is bounded here by scoping role actions to the `vigil-*` name
  prefix and `iam:PassRole` to `ecs-tasks.amazonaws.com`.
- The main stack's GitHub Actions **CI role** is a separate identity (created by
  the main stack via OIDC, no static keys). If you want CI to run a full
  `terraform apply` (not just image build + ECS rollout), that role needs the
  same deploy permissions as this user — attach these two managed policies to
  it as well, or narrow CI to build/rollout only.
- Destroy with `terraform destroy` here only after the main stack is torn down
  (the bucket must be empty, and the deployer must no longer be in use).
