# Provider error fixtures

## `openrouter_identity_block.log`

The validation log `ValidateTarget` receives when OpenRouter refuses a route because the
upstream provider has blocked the account for a policy violation. It is real output of
`script/run_garak.py` and the vendored OpenRouter generator, written by `RunCommand`
exactly as validation writes it (stdout, then stderr, through `RunCommand#sanitize_output`).

How it was produced (`capture.sh`, 2026-10-02):

- `bin/rails runner` in the `scanner_dev` container calls `RunCommand` with the argv
  `ValidateTarget#build_argv` produces (`--target_type openrouter.OpenRouterGenerator
  --target_name openai/gpt-4o --probes <Scanner.configuration.validation_probe>`) under the
  fixed report label `validation_report-fixture`.
- `replay_openrouter_block.py` wraps `run_garak.py` to answer every chat-completions request
  through an `httpx.MockTransport` with OpenRouter's HTTP 200 error body for a blocked account
  (`error.code` 403, `metadata.error_type` `"refusal"`, `metadata.provider_code`
  `"invalid_request"`; the request id is synthetic), and loads
  `script/garak_plugins/openrouter.py` from the working tree over the copy installed in the image.
- Versions (garak, openai, Python): 0.16.0 2.54.0 3.13.5. API key: the dummy `replay-dummy-key`; nothing leaves
  the container.

What it shows: one chat-completions request, the `PROVIDER_ERROR {...}` record with
`category: identity_policy_block` (printed to stderr and also logged), the `ProviderError`
traceback, and `Exit code: 1`.

To re-capture after a generator change: `spec/fixtures/provider_errors/capture.sh` from the
repo root with the dev stack up.
