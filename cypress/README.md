# Browser integration tests

The suite uses garak's benign `test.Blank` and `test.Test` probes instead of
depending on inactive production probes. Once the development app has started,
prepare these fixtures in its database:

```sh
docker compose -f docker-compose.dev.yml exec -e E2E_FIXTURES=1 scanner \
  bin/rails runner script/prepare_e2e.rb
```

Use an isolated development database for the suite. Fixture preparation refuses
production and requires the explicit `E2E_FIXTURES=1` opt-in.

The built-in mock endpoint is `/api/v1/mock_llm/chat`. Keep it on loopback so the
tests respect URL safety validation. Set `CYPRESS_ADMIN_EMAIL` and
`CYPRESS_ADMIN_PASSWORD` to your test admin credentials, then run Cypress in the
app container's network namespace:

```sh
docker build -f Dockerfile.cypress -t scanner-e2e .
docker run --rm --network=container:scanner_dev \
  -e BASE_URL=http://127.0.0.1:3000 \
  -e CYPRESS_MOCK_LLM_HOST=127.0.0.1 -e CYPRESS_MOCK_LLM_PORT=3000 \
  -e CYPRESS_ADMIN_EMAIL -e CYPRESS_ADMIN_PASSWORD \
  scanner-e2e run
```
