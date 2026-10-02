#!/usr/bin/env bash
# Re-capture openrouter_identity_block.log. Run from the repo root with the dev
# stack up (docker compose -f docker-compose.dev.yml up -d). See README.md.
set -euo pipefail
docker compose -f docker-compose.dev.yml exec -T scanner bash -lc 'cd /rails && bin/rails runner "
uuid = %q(validation_report-fixture)
log = Rails.root.join(%q(spec/fixtures/provider_errors/openrouter_identity_block.log)).to_s
File.delete(log) if File.exist?(log)
argv = [%q(/opt/venv/bin/python3), %q(/rails/spec/fixtures/provider_errors/replay_openrouter_block.py), uuid,
        %q(--target_type), %q(openrouter.OpenRouterGenerator), %q(--target_name), %q(openai/gpt-4o),
        %q(--probes), Scanner.configuration.validation_probe, %q(--report_prefix), uuid]
begin
  RunCommand.new(argv, env: { %q(HOME) => %q(/home/rails), %q(OPENROUTER_API_KEY) => %q(replay-dummy-key) }).call(log_file: log)
  puts %q(EXIT=0)
rescue => e
  puts %q(RunCommand raised: garak exited non-zero)
end
"'
