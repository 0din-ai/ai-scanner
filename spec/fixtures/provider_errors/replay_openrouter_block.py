"""Answer every OpenRouter chat-completions request with the HTTP 200 error body
OpenRouter returns when the upstream provider has blocked the account, then run
script/run_garak.py exactly as ValidateTarget does. See README.md."""
import runpy, sys

# Production order: run_garak.py imports db_notifier (whose import-time basicConfig
# sends root logging to stderr) before anything imports garak. Keep that order.
sys.path.insert(0, "/rails/script")
import db_notifier  # noqa: E402,F401

import httpx, openai  # noqa: E402

BODY = {
    "id": "gen-1700000000-fixtureReplayBody00",
    "error": {
        "message": "Policy Violation: this user has been blocked for a previous policy violation. "
                   "Learn more: https://platform.openai.com/docs/guides/safety-best-practices",
        "code": 403,
        "metadata": {"error_type": "refusal", "provider_code": "invalid_request"},
    },
}
CALLS = []


def handler(request):
    CALLS.append(request.url.path)
    print(f"REPLAY call #{len(CALLS)} {request.method} {request.url}", file=sys.stderr)
    return httpx.Response(200, json=BODY)


_orig_init = openai.OpenAI.__init__


def _init(self, *a, **kw):
    kw["http_client"] = httpx.Client(transport=httpx.MockTransport(handler))
    _orig_init(self, *a, **kw)


openai.OpenAI.__init__ = _init

# The image copies script/garak_plugins/openrouter.py into site-packages at build
# time; load the working-tree copy over it so the capture reflects the source.
import importlib.util, garak.generators  # noqa: E402,E401
spec = importlib.util.spec_from_file_location(
    "garak.generators.openrouter", "/rails/script/garak_plugins/openrouter.py"
)
mod = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = mod
spec.loader.exec_module(mod)
garak.generators.openrouter = mod

sys.argv = ["/rails/script/run_garak.py"] + sys.argv[1:]
runpy.run_path("/rails/script/run_garak.py", run_name="__main__")
