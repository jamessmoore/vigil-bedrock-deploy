# Bifrost configuration

This directory holds the only Vigil-specific artifact this repo owns: Bifrost's
seed configuration. It defines provider credentials and the routing/fallback
behavior that makes Vigil run primary LLM traffic through **AWS Bedrock** while
keeping **Anthropic** and **OpenAI** as configured fallbacks — all without
touching any Vigil application code.

## `config.json.tftpl`

This is a **Terraform template**, not standalone JSON — it carries two
substitutions that Terraform fills in at apply time:

| Placeholder                 | Source                                              |
| --------------------------- | --------------------------------------------------- |
| `${aws_region}`             | `var.aws_region`                                    |
| `${bedrock_sonnet_model_id}`| `var.bedrock_sonnet_model_id` (the Bedrock inference-profile ID) |

The ECS module renders it with `templatefile()` and seeds the result into the
Bifrost container at `/app/data/config.json` via a tiny init container, so the
stock `maximhq/bifrost` image is used unmodified.

## How routing works

- **Providers** — `bedrock` (auth via the ECS task role's SigV4 credentials, no
  key), `anthropic` (`env.ANTHROPIC_API_KEY`), `openai` (`env.OPENAI_API_KEY`).
  The two fallback keys are injected from Secrets Manager into the task
  definition; they are never written into this file.
- **Routing rule** — a global governance rule matches any `claude*` model and
  sends it to Bedrock as the primary target, with Anthropic-direct and OpenAI as
  ordered fallbacks. Bifrost's fallback chain is otherwise a per-request
  parameter; a global routing rule is the config-only way to make Bedrock
  primary for traffic the app sends through the gateway.

## Important: confirm the Bedrock model ID and verify the passthrough path

1. **Model ID.** `bedrock_sonnet_model_id` must be the real Bedrock identifier
   for Claude Sonnet 4.6 in your region — for cross-region inference, the
   inference-profile ID (e.g. `us.anthropic.claude-sonnet-4-6-YYYYMMDD-v1:0`).
   Look it up; do not trust a guessed dated suffix:
   ```bash
   aws bedrock list-inference-profiles --region <region> \
     --query "inferenceProfileSummaries[?contains(inferenceProfileName,'Sonnet 4.6')]"
   ```
   The same value drives the scoped `bedrock:InvokeModel*` IAM policy ARNs.

2. **Passthrough verification.** Vigil routes Anthropic-bound traffic through
   Bifrost's `/anthropic` passthrough. After deploying, confirm in Bifrost's
   logs (the `core` routing-engine trail) that Claude requests are actually
   served by `bedrock`. If the passthrough surface bypasses governance routing
   in your Bifrost version, point Vigil's model configuration at a
   `bedrock/`-prefixed model, or pin the provider in Bifrost directly — the
   routing rule here is the intended mechanism, but the passthrough behavior is
   the one thing to validate before trusting the Bedrock path in production.
