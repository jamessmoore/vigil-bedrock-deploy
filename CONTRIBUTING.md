# Contributing

Thanks for your interest in this project. It's currently maintained solo by James Moore, with Claude (Anthropic) used as a development collaborator — see [CONTRIBUTORS.md](CONTRIBUTORS.md) for details on how AI tooling is used here.

## Current Status

This is an actively developed solo project. There's no formal contribution process yet, but the guidelines below will apply once outside contributions are accepted.

## How to Contribute

1. **Open an issue first** for anything beyond a trivial fix (typos, broken links, small docs corrections). This avoids duplicate work and lets us agree on approach before you write code.
2. **Fork the repo** and create a feature branch off `master`:
   ```bash
   git checkout -b fix/short-description
   ```
3. **Keep PRs focused.** One fix or feature per PR. Large, multi-purpose PRs are harder to review and more likely to get bounced back.
4. **Write clear commit messages.** Imperative mood, short summary line, body if needed:
   ```
   Scope soc-daemon webhook health check to port 9091
   ```
5. **Include tests/validation where applicable.** This is an infrastructure repo — at minimum, `terraform fmt` and `terraform validate` must pass (see "Local verification" below).
6. **Update documentation** if your change affects setup, configuration, or usage.

## Code Style

- Match the existing style/formatting conventions already in the codebase.
- Prefer clarity over cleverness — this codebase favors readable, maintainable Terraform over dense one-liners. Comment the non-obvious (tradeoffs, wildcard-IAM exceptions, cross-module wiring).
- Run `terraform fmt -recursive` before submitting.

## Local verification

This mirrors the `test` CI check (`.github/workflows/test.yml`) — if these pass locally, the status check will pass:

```bash
terraform fmt -check -recursive terraform
cd terraform/environments/prod
terraform init -backend=false
terraform validate
```

## Pull Request Process

1. Ensure your branch is up to date with `master` before opening the PR.
2. Describe **what** changed and **why** in the PR description — link the related issue if one exists.
3. Be responsive to review feedback. PRs that go stale without updates may be closed.
4. The `test` CI check (`terraform fmt` + `terraform validate` — see `.github/workflows/test.yml`) must pass before merge. `master` is protected: no direct pushes, no force-pushes, no branch deletion, and no bypassing the PR requirement, even for repo admins.

## Reporting Bugs

Open an issue with:
- A clear, descriptive title
- Steps to reproduce
- Expected vs. actual behavior
- Environment details (Terraform/AWS provider versions, region) if relevant

## Code of Conduct

Be respectful and constructive. Disagreements about technical approach are fine and expected — personal attacks or bad-faith engagement are not.

---

Questions? Open an issue or reach out via [webtechhq.com](https://webtechhq.com).
