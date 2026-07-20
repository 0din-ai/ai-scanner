# Scanner

An open-source web application for AI model security assessments, built with Ruby on Rails and [NVIDIA garak](https://github.com/NVIDIA/garak). Scanner helps organizations test their AI systems for vulnerabilities before deployment — similar to penetration testing for traditional software.

📖 **[Full documentation →](https://0din.ai/docs/scanner-introduction?utm_source=github&utm_medium=readme&utm_campaign=opensourcescanner)**

<p align="center">
  <img src="https://static.0din.ai/assets/marketing/scanner-0356fb6d.png" alt="0DIN Scanner" width="800">
</p>

## Featured Vulnerabilities

Scanner ships with real, 0DIN-disclosed jailbreaks as ready-to-run probes - not simulations. Six of them are highlighted below, each bundled with the original attack prompt plus 34 retargetable variants and linked to its public threat report (affected models, taxonomy, reproducibility scores, and mitigations).

| Tactic | Scanner probe | Threat report |
|--------|---------------|---------------|
| Placeholder Injection | `PlaceholderInjectionHP` | [View ↗](https://0din.ai/threatfeed/8ccd7f81-4e36-4084-8061-cec6e2d83ece/public?utm_source=0din.ai&utm_medium=open_source_scanner&utm_campaign=opensourcescanner&utm_content=placeholder_injection) |
| Incremental Table Completion | `IncrementalTableCompletionCM` | [View ↗](https://0din.ai/threatfeed/0d1e2015-f6ce-4b79-8bde-edd26bfc6f02/public?utm_source=0din.ai&utm_medium=open_source_scanner&utm_campaign=opensourcescanner&utm_content=incremental_table_completion) |
| Technical Field Guide | `TechnicalFieldGuideCM` | [View ↗](https://0din.ai/threatfeed/a50c962f-1a46-4382-b810-9a2b4c5c6091/public?utm_source=0din.ai&utm_medium=open_source_scanner&utm_campaign=opensourcescanner&utm_content=technical_field_guide) |
| Chemical Compiler Debug | `ChemicalCompilerDebugCM` | [View ↗](https://0din.ai/threatfeed/4e8ed295-a772-4a29-8727-cbefada44123/public?utm_source=0din.ai&utm_medium=open_source_scanner&utm_campaign=opensourcescanner&utm_content=chemical_compiler_debug) |
| Correction | `CorrectionCM` | [View ↗](https://0din.ai/threatfeed/439777fa-377a-43cb-83c6-c1a012e384b1/public?utm_source=0din.ai&utm_medium=open_source_scanner&utm_campaign=opensourcescanner&utm_content=correction) |
| Hex Recipe Book | `HexRecipeBookCM` | [View ↗](https://0din.ai/threatfeed/06b58763-8a7b-4d82-afb6-ebe738b378a4/public?utm_source=0din.ai&utm_medium=open_source_scanner&utm_campaign=opensourcescanner&utm_content=hex_recipe_book) |

See the full [Featured Vulnerabilities guide](https://0din-ai.github.io/ai-scanner/getting-started/featured-vulnerabilities) for what each tactic does and how to run them against your own targets.

## Features

- **179 community probes** across 35 vulnerability families, aligned with the [OWASP LLM Top 10](https://owasp.org/www-project-top-10-for-large-language-model-applications/)
- **Multi-target scanning** — test API-based LLMs and browser-based chat UIs
- **Scheduled and on-demand scans** with configurable recurrence
- **Attack Success Rate (ASR)** scoring with trend tracking across scan runs
- **Live Activity Stream** — monitor queued and running scans with database-backed execution-log tails and final report logs
- **PDF report export** with per-probe, per-attempt drill-down
- **SIEM integration** — forward results to Splunk or Rsyslog
- **Multi-tenant** — multiple organizations on a single deployment, data encrypted at rest
- **No artificial limits** — all features unlocked, unlimited scans and users

## Community & Enterprise

Join the community, share feedback, or talk to us about a turn-key SaaS deployment — everything lives on the [Scanner landing page](https://0din.ai/marketing/open_source_scanner?utm_source=github&utm_medium=readme&utm_campaign=opensourcescanner).

## Quick Start

```bash
curl -sL https://raw.githubusercontent.com/0din-ai/ai-scanner/main/scripts/install.sh | bash
```

Or manually:

```bash
curl -O https://raw.githubusercontent.com/0din-ai/ai-scanner/main/dist/docker-compose.yml
curl -O https://raw.githubusercontent.com/0din-ai/ai-scanner/main/.env.example
cp .env.example .env
# Edit .env: set SECRET_KEY_BASE (openssl rand -hex 64), POSTGRES_PASSWORD, and ADMIN_INITIAL_PASSWORD
docker compose up -d
```

Open `http://localhost` and log in with `admin@example.com` and the `ADMIN_INITIAL_PASSWORD` value from your `.env` file. **Change the initial password immediately.**

See the [Quick Start guide](https://0din.ai/docs/getting-started/quick-start?utm_source=github&utm_medium=readme&utm_campaign=opensourcescanner) for full instructions including port configuration, first scan walkthrough, and troubleshooting.

## Documentation

| | |
|---|---|
| [Quick Start](https://0din.ai/docs/getting-started/quick-start?utm_source=github&utm_medium=readme&utm_campaign=opensourcescanner) | Get running in minutes |
| [First Scan](https://0din.ai/docs/getting-started/first-scan?utm_source=github&utm_medium=readme&utm_campaign=opensourcescanner) | Run your first scan with the built-in Mock LLM |
| [User Guide](https://0din.ai/docs/user-guide/core-concepts?utm_source=github&utm_medium=readme&utm_campaign=opensourcescanner) | Targets, scanning, reports, probes, integrations |
| [Deployment](https://0din.ai/docs/deployment/docker-compose?utm_source=github&utm_medium=readme&utm_campaign=opensourcescanner) | Production deployment, TLS, database configuration |
| [Development](https://0din.ai/docs/development/setup?utm_source=github&utm_medium=readme&utm_campaign=opensourcescanner) | Dev setup, architecture, extension points |
| [Troubleshooting](https://0din.ai/docs/troubleshooting?utm_source=github&utm_medium=readme&utm_campaign=opensourcescanner) | Common issues and solutions |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, branch conventions, and the PR process.

To report a security vulnerability, see [SECURITY.md](SECURITY.md).

## License

This project is licensed under the Apache License 2.0. See [LICENSE](LICENSE) for details.
