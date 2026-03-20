# Scanner

An open-source web application for AI model security assessments, built with Ruby on Rails and [NVIDIA garak](https://github.com/NVIDIA/garak). Scanner helps organizations test their AI systems for vulnerabilities before deployment — similar to penetration testing for traditional software.

📖 **[Full documentation →](https://0din-ai.github.io/ai-scanner/)** · 🎬 **[Request a demo →](https://0din.ai/marketing/scanner)**

## Features

- **179 community probes** across 35 vulnerability families, aligned with the [OWASP LLM Top 10](https://owasp.org/www-project-top-10-for-large-language-model-applications/)
- **Multi-target scanning** — test API-based LLMs and browser-based chat UIs
- **Scheduled and on-demand scans** with configurable recurrence
- **Attack Success Rate (ASR)** scoring with trend tracking across scan runs
- **PDF report export** with per-probe, per-attempt drill-down
- **SIEM integration** — forward results to Splunk or Rsyslog
- **Multi-tenant** — multiple organizations on a single deployment, data encrypted at rest
- **No artificial limits** — all features unlocked, unlimited scans and users

## Quick Start

```bash
curl -O https://raw.githubusercontent.com/0din-ai/ai-scanner/main/dist/docker-compose.yml
curl -O https://raw.githubusercontent.com/0din-ai/ai-scanner/main/.env.example
cp .env.example .env
# Edit .env: set SECRET_KEY_BASE (openssl rand -hex 64) and POSTGRES_PASSWORD
docker compose up -d
```

Open `http://localhost` and log in with `admin@example.com` / `password`. **Change the default password immediately.**

See the [Quick Start guide](https://0din-ai.github.io/ai-scanner/getting-started/quick-start) for full instructions including port configuration, first scan walkthrough, and troubleshooting.

## Documentation

| | |
|---|---|
| [Quick Start](https://0din-ai.github.io/ai-scanner/getting-started/quick-start) | Get running in minutes |
| [First Scan](https://0din-ai.github.io/ai-scanner/getting-started/first-scan) | Run your first scan with the built-in Mock LLM |
| [User Guide](https://0din-ai.github.io/ai-scanner/user-guide/core-concepts) | Targets, scanning, reports, probes, integrations |
| [Deployment](https://0din-ai.github.io/ai-scanner/deployment/docker-compose) | Production deployment, TLS, database configuration |
| [Development](https://0din-ai.github.io/ai-scanner/development/setup) | Dev setup, architecture, extension points |
| [Troubleshooting](https://0din-ai.github.io/ai-scanner/troubleshooting) | Common issues and solutions |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, branch conventions, and the PR process.

To report a security vulnerability, see [SECURITY.md](SECURITY.md).

## License

This project is licensed under the Apache License 2.0. See [LICENSE](LICENSE) for details.
