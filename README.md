# Scanner

An open-source web application for AI model security assessments, built with Ruby on Rails and [NVIDIA garak](https://github.com/NVIDIA/garak). Scanner helps organizations test their AI systems for vulnerabilities before deployment — similar to penetration testing for traditional software.

📖 **[Full documentation →](https://0din.ai/docs/scanner-introduction?utm_source=github&utm_medium=readme&utm_campaign=opensourcescanner)**

<p align="center">
  <img src="https://static.0din.ai/assets/marketing/scanner-0356fb6d.png" alt="0DIN Scanner" width="800">
</p>

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
