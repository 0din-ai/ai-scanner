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

### App-specific development credentials (optional)

Use one team-shared Scanner app Environment for both public and private distributions, containing only Scanner's required local secrets and its distinct `OPENROUTER_API_KEY` when OpenRouter is used. Portal has its own Environment and different key. Never use a common all-app base or duplicate keys in overlays. Ask the owner to provision values and access before use; metadata alone is insufficient.

Install [1Password CLI](https://developer.1password.com/docs/cli/get-started/) first (`brew install --cask 1password-cli` on macOS). Enable desktop **Developer → Integrate with 1Password CLI**, unlock the app, and run `op signin`. Request team access, then copy the nonsecret Environment ID from **Developer → View Environments → View environment → Manage environment → Copy environment ID** into your local `OP_DEV_ENV_ID`; never copy or print the key.

```bash
op run --environment "$OP_DEV_ENV_ID" -- docker compose -f docker-compose.dev.yml up
```

`OP_DEV_ENV_ID` is this project's developer-local, nonsecret Scanner app Environment selector, used by either Scanner distribution but not Portal. Do not commit selectors or credentials. Compose forwards `OPENROUTER_API_KEY` only to the development app. Set the global canonical value in the UI to `env:OPENROUTER_API_KEY`; the encrypted database stores the reference, not the key. Normal target/global precedence remains except that the injected canonical development key wins over stale stored `OPENROUTER_API_KEY` values. Offline/non-OpenRouter/customer workflows remain unchanged.

This reference is development-only. Other references and references in production are rejected; explicit per-tenant credential values continue to work unchanged. `OPENAI_API_KEY` can use the reference explicitly when the target provider expects that variable; the scanner does not rewrite other provider names automatically. Build images without injected credentials before launch. For direct `bin/dev` use, preinstall Foreman with `gem install foreman` in a credential-free shell.

`bin/setup` can run `bundle install` when dependencies are missing. Run it without injected app credentials; do not wrap it in `op run`. Setup/devcontainer installers inherit their process environment: injection is not a dependency-execution sandbox.

After rotation, recreate the scanner container and its web/workers under fresh injection:

```bash
op run --environment "$OP_DEV_ENV_ID" -- docker compose -f docker-compose.dev.yml up -d --no-deps --force-recreate scanner
```

`docker compose restart` retains the old container environment; it does not refresh the key.

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

> Commit types determine the **version bump** when a release is cut — they do **not** auto-release on merge. A maintainer cuts a release on demand via **Actions → Release → Run workflow** (on `main`), which bundles every change since the last release.

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
