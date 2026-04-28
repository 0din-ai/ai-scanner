---
sidebar_position: 2
---

# Testing

All test commands run **inside the dev container**.

```bash
docker compose -f docker-compose.dev.yml exec scanner /bin/bash
```

## RSpec

```bash
# Run all specs
RAILS_ENV=test bundle exec rspec

# Run a specific file
RAILS_ENV=test bundle exec rspec spec/models/target_spec.rb

# Run with coverage report
RAILS_ENV=test COVERAGE=true bundle exec rspec
```

:::warning Always use RAILS_ENV=test
Without `RAILS_ENV=test`, RSpec will run against the development database.
:::

## Static Analysis

```bash
# Python notifier/runner tests
python3 -m unittest discover -s script/tests
python3 -m py_compile script/db_notifier.py script/run_garak.py

# Stimulus controller tests
npm run test:js

# Security scan (Brakeman)
bundle exec brakeman

# Linter (RuboCop)
bundle exec rubocop

# Auto-fix RuboCop violations
bundle exec rubocop -A

# Check for vulnerable JavaScript dependencies
bundle exec importmap audit
```

## End-to-End Tests (Cypress)

Cypress runs on the **host machine** (not in Docker) and requires Node.js:

```bash
# Install dependencies (first time)
npm install

# Open Cypress test runner (interactive)
npm run cypress:open

# Run headlessly
npm run cypress:run
```

## CI Pipeline

The CI workflow (`.github/workflows/ci.yml`) runs on every PR:

1. Garak lock file validation
2. Brakeman security scan
3. Importmap audit
4. RuboCop lint
5. RSpec with coverage

All checks must pass before merging.

## Testing Garak Integration

Stub garak execution in tests to avoid real subprocess calls:

```ruby
allow_any_instance_of(RunGarakScan).to receive(:call)
```

For live progress and execution-log behavior, mock `JournalSyncThread` and database notifier behavior rather than local socket communication.

## Test Factories

Test data is defined using FactoryBot in `spec/factories/`. Key factories:

| Factory | Model |
|---|---|
| `:company` | Multi-tenant organization |
| `:user` | Admin or regular user |
| `:target` | Scan target (API or webchat) |
| `:scan` | Scan configuration |
| `:report` | Completed scan report |
| `:output_server` | SIEM integration |
