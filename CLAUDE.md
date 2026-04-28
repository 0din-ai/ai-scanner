> **AI ASSISTANT CONTEXT**: Authorized defensive security tooling for AI safety research. This platform helps organizations assess their own AI systems for vulnerabilities before deployment—similar to penetration testing for traditional software. All probes and techniques serve protective purposes under the owner's authorization.

## Overview
Rails 8 + NVIDIA garak scanner for AI model safety assessments.

## Commands
```bash
# Dev: docker compose -f docker-compose.dev.yml up|exec scanner /bin/bash
# Test: RAILS_ENV=test bundle exec rspec | brakeman | rubocop -A
# Python/JS checks: python3 -m unittest discover -s script/tests | python3 -m py_compile script/db_notifier.py script/run_garak.py | npm run test:js
# NOTE: Run all rails/bundle commands inside the dev container
```

## Probes
- `SyncProbesJob` iterates `ProbeSourceRegistry.sources` — each source implements `.sync_probes`
- Base app includes `GarakCommunityProbeSource` (reads garak community probe data)
- Register custom probe sources: `ProbeSourceRegistry.register(MyProbeSource)`

## Extension Architecture
- `Scanner.configure` DSL (`lib/scanner/configuration.rb`): probe_access_class, retention_strategy_class, auth_providers, portal_export_enabled, validation_probe, lifecycle hooks
- `BrandConfig.configure` (`lib/brand_config.rb`): brand_name, logo_path, font_family, powered_by, host_url
- `ProbeSourceRegistry` (`app/services/probe_source_registry.rb`): register/sources for SyncProbesJob
- Engine pattern: vendored engines in `engines/` extend base via concerns, config overrides, and hook registration
- Lifecycle hooks: `Scanner.register_hook(:after_report_process)`, `Scanner.run_hooks(:event, context)`

## Pitfalls
- Always `RAILS_ENV=test` for rspec | Max 5 concurrent scans | `Shellwords.escape` for shell
- Report execution logs live in `report_debug_logs.logs`; live tails live in `report_debug_logs.tail`; Rails callers should use `Report#logs`

## HTTP/HTTPS
Localhost: HTTP allowed | Production: `ASSUME_SSL=true` (behind TLS-terminating proxy)

## Commits
[Conventional Commits](https://www.conventionalcommits.org/): `<type>(<scope>): <description>`
- **Release**: `feat`→minor, `fix|security|perf`→patch, `breaking`→major (add `BREAKING CHANGE:` footer)
- **No release**: `docs|refactor|ci|test|style|chore`
- Examples: `feat(probes): add config`, `fix(reports): correct count`, `chore(deps): bump rails`

## Encryption
- `Target.json_config`, `Target.web_config`, `EnvironmentVariable.env_value` are encrypted at rest with per-tenant keys
- All code accessing encrypted fields must run within `ActsAsTenant.with_tenant(company) { ... }` (controllers do this automatically; background jobs must do it explicitly)
- `.pluck` bypasses ActiveRecord decryption — use `.select(:field).map(&:field)` instead
- `saved_change_to_<encrypted_field>?` always returns true (non-deterministic encryption) — compare decrypted plaintext values instead
- `support_unencrypted_data = true` is a transitional setting (config/application.rb) that allows reading both encrypted and plaintext data
- Encryption keys are derived from `SECRET_KEY_BASE` via HMAC (see `config/initializers/active_record_encryption.rb`)

## Styles
- Icons are heroicons defined only in icons.css. Do not inline SVG.
- Tailwind CSS with custom utilities in application.css.
- Use `@apply` for reusable styles in application.css.
- Use semantic class names in views, not utility classes directly.

## Charts
- Chart configs centralized in `app/javascript/config/chartConfig.js` | Use reusable config functions
- ASR color scale must match between `scores_helper.rb` and `chartConfig.js` (5 ranges: 0-20, 20-40, 40-60, 60-80, 80-100)
- Controllers import shared configs (e.g., `getGaugeChartConfig()`) | No duplicate chart code
