# Contributing to Expi

Thanks for your interest in contributing to Expi.

## Before You Start

- Check existing issues and PRs to avoid duplicate work.
- For larger changes, open an issue first and confirm scope before implementation.
- Keep changes focused and small when possible.

## Development Workflow

1. Fork and clone the repository.
2. Create a focused branch (`feat/...`, `fix/...`, or `docs/...`).
3. Implement changes with tests.
4. Run quality gates locally:
   - `mix compile --warnings-as-errors`
   - `mix credo --strict`
   - `mix test --exclude integration`
5. Update docs and changelog entries when behavior or APIs change.
6. Open a pull request with clear context and rationale.

## Commit and PR Hygiene

- Use clear commit messages in imperative mood (e.g., `Add ...`, `Fix ...`).
- Keep PRs scoped to a single concern.
- Include:
  - What changed
  - Why it changed
  - How it was validated
  - Any follow-up work

## Testing Expectations

- Add or update tests for every behavior change.
- Do not merge with warnings or strict Credo violations.
- Credential-dependent integration tests are optional for local contribution flow, but should be run when touching provider integration behavior.

## Documentation Expectations

When changing user-facing behavior, update relevant docs:

- `README.md`
- Files under `docs/`
- `CHANGELOG.md` (under `Unreleased`)

## Review Etiquette

- Be constructive and specific in review comments.
- Assume positive intent.
- Resolve feedback with follow-up commits; avoid force-push unless requested.

## Code of Conduct

By participating, you agree to collaborate respectfully and professionally.
