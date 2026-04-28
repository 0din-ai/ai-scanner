# Contributing

Thanks for helping improve Scanner! These guidelines describe the preferred workflow and standards.

## Getting Started

1. Fork the repository
2. Clone your fork and configure the environment:
   ```bash
   cp .env.example .env
   # Edit .env: set SECRET_KEY_BASE (openssl rand -hex 64) and POSTGRES_PASSWORD
   ```
3. Build and start the dev environment:
   ```bash
   docker compose -f docker-compose.dev.yml build
   docker compose -f docker-compose.dev.yml up
   ```
   The database is set up automatically on first boot.
4. Create a feature branch from `main`:
   ```bash
   git checkout -b feature/my-feature main
   ```

## Development Workflow

Run tests locally before opening a PR:

```bash
# Inside the dev container:
RAILS_ENV=test bundle exec rspec   # Always use RAILS_ENV=test
python3 -m unittest discover -s script/tests
python3 -m py_compile script/db_notifier.py script/run_garak.py
npm run test:js
rubocop -A                          # Linter with auto-fix
brakeman                            # Security scanner
```

## Branch Naming

Use descriptive, short names:
- `feature/short-description` — new feature
- `fix/short-description` — bug fix
- `chore/short-description` — maintenance
- `docs/short-description` — documentation
- `hotfix/short-description` — urgent fixes

Examples:
- `feature/add-json-validator`
- `fix/escape-file-paths-mac`

## Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/): `<type>(<scope>): <subject>`

**Types:**
- `feat` — new feature (triggers minor release)
- `fix` — bug fix (triggers patch release)
- `security` / `perf` — triggers patch release
- `docs` / `refactor` / `test` / `style` / `chore` / `ci` — no release

Keep subject lines <= 72 characters. Include a body when more context is needed.

**Examples:**
```
feat(probes): add community probe filtering
fix(reports): correct scan count in summary
docs: update contributing guide
```

## Pull Requests

- PR title should follow Conventional Commits style
- In the PR description include:
  - Problem statement
  - Solution summary
  - Test plan and how to validate locally (include Docker commands)
- Keep PRs focused — ideally under ~300 lines of changes
- Target the `main` branch

### PR Checklist

- [ ] Tests pass (`RAILS_ENV=test bundle exec rspec`)
- [ ] No RuboCop violations (`rubocop`)
- [ ] No security issues (`brakeman`)
- [ ] Commit messages follow conventional commits format

## Reviews & Approvals

- At least one approving review required for non-critical changes
- Two approvals for changes that touch core services, background jobs, migrations, or security-sensitive code
- Reviewers should verify:
  - Tests cover new behavior and all tests pass
  - No sensitive credentials are added
  - DB migrations are safe and reversible
  - Performance and concurrency implications considered

## Tests & Quality

- Add unit tests for model, service, and job changes
- Stub garak execution in tests: `allow_any_instance_of(RunGarakScan).to receive(:call)`
- Mock `JournalSyncThread` and database notifier behavior for garak integration paths
- Run rubocop and fix warnings before opening a PR

## Architecture

Scanner uses an extensible architecture with three main extension points:

- **Scanner.configure** — configuration DSL for service classes, feature flags, and lifecycle hooks
- **BrandConfig.configure** — theming and branding (logo, fonts, footer text)
- **ProbeSourceRegistry** — register additional probe data sources for `SyncProbesJob`

See the [Architecture](README.md#architecture) section in the README for details.

## Migrations

- Keep migrations small and reversible
- Document migration plans in the PR for changes requiring downtime
- Ensure migrations run in CI and locally

## Security & Secrets

- Never commit secrets or private keys
- Use environment variables for credentials and document them in `.env.example`
- For security-sensitive changes, request an additional security review
- If you discover a security vulnerability, please follow the process in [SECURITY.md](SECURITY.md) — do not open a public issue

## License

By contributing, you agree that your contributions will be licensed under the [Apache License 2.0](LICENSE).
