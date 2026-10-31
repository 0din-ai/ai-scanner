---
name: model-gateway-and-infrastructure
description: Attack the tier between the chat surface and the model, the LLM proxy/router (LiteLLM, OpenRouter, Kong AI Gateway, Portkey, a vendor gateway). SSRF and provider-credential exfiltration through routing parameters, auth bypass on management routes, injection in key verification, cross-key/tenant and budget isolation, denial-of-wallet. Scope-gated hardest of all, only when the customer owns the gateway.
---

# Playbook: model gateway and infrastructure

**Objective.** Find a vulnerability in the infrastructure that sits *between* the chat surface and
the model, the LLM gateway, proxy, or router the request passes through. This is the one playbook
that leaves the model's conversation and tests the plumbing, so it borrows the classic web classes
(SSRF, auth bypass, injection, CSRF) and aims them at a component with a real and active CVE record.

> [!NOTE]
> **Sibling, pick by tier.** This playbook is the *router* tier between the chat surface and the
> model, an LLM proxy the customer owns, where the SSRF rides a model-routing parameter (`api_base`,
> `user_config`). `chatbot-provider-ssrf-csrf` is the *application* plumbing around the widget, a URL
> the assistant fetches on the customer's own app, the link/image it emits, the widget's own CSRF.
> Route by which tier carries the flaw.

> [!IMPORTANT]
> **Scope first, before any active probe.** The gateway is in scope only when the **customer owns
> it**. A hosted or shared gateway, LiteLLM Cloud, OpenRouter, a vendor's managed router, any
> multi-tenant proxy, is a third party under `no_third_party_pivot`, and attacking it hits other
> tenants and the vendor. Confirm ownership from recon; if it is not clearly the
> customer's own deployment, send no active request and name the scope gap under Not covered.
> A request you did not send is not a closed investigation. Even on a customer-owned gateway, prove
> with a designated synthetic canary and the smallest request, never a live customer record or key.
> Establish the tested principal's actual authorization; an intended management operation is a control.

**When to choose it.** Recon fingerprinted a proxy/router tier: an OpenAI-compatible
`/v1/chat/completions` endpoint the front end talks to directly, a LiteLLM/gateway error signature
or version banner, an exposed `/health`, `/models`, or admin/config route, or a `model` field whose
values name a routing alias rather than a vendor model.

## Method by class (each mapped to a real gateway CVE pattern)

1. **SSRF and provider-credential exfiltration.** Gateways route the outbound provider call from
   caller-supplied fields. Where the request body carries a routing parameter, `api_base`,
   `base_url`, `model_list`, `fallbacks`, or one **nested inside** an object like `user_config`, a
   caller can redirect the outbound call. The proof of an off-scope redirect is a marker you minted
   at an approved operator-controlled canary, never a public request bin. If no approved canary was
   given in the operator's notes, do not send the redirect. Name the missing canary under Not
   covered. If that redirect would carry a credential, session, or customer record, or you cannot
   tell whether the proxy would attach a provider key, do not send, and say so under Not covered.
   Do not record a closed lead for a request you did not send. An ordinary in-scope call the
   product is meant to make to its provider stays allowed. A callback that carries only the minted
   marker is not sensitive data exposure, and a bare ordinary fetch is not that class. Record a
   closed investigation only when you sent the request, observed that result, and it meets no class
   bar. It is server-side request forgery when the product executor reached a destination it is
   independently forbidden to reach and that destination answered or caused an effect, sensitive
   data exposure when protected synthetic data actually flowed to an audience that should not have
   it without you placing that secret on the proof request, and prompt injection when planted
   content caused an action the request shows. Echoing the marker text does not count. Do not
   capture or keep the real upstream key; describe it by role. If a supported effect is proven,
   record the finding and stop. Use `scanner_record_closed_lead` only for an investigation you tried
   whose observed result meets no finding bar.
2. **Authentication bypass on management routes.** The auth gate often derives the effective route
   from a spoofable input. Test a crafted `Host` header (route reconstructed from `Host` can make
   the gate evaluate a different route than the one dispatched), an OIDC/userinfo cache-key
   collision, an OAuth passthrough fallback, and pass-the-hash where a password hash is exposed.
   Use only a named synthetic user/key or a controlled test response; never request an unfiltered
   user/admin view. For user-info routes, supply the designated synthetic user ID and establish that
   the selected user has only canary keys and metadata, because the response can include their keys.
   If the bypass ignores the selector or cannot be bounded without exposing live records, leave it
   under Not covered. Success requires protected canary data returned to an unauthorized caller,
   not merely an HTTP 200 or an accessible route name. Keep proof read-only.
3. **Injection in the request path.** Caller-supplied values sometimes reach a query or template
   unparameterized: an `Authorization` header or key value concatenated into the key-verification
   SQL (reachable even unauthenticated through an error path), a `key` parameter on `/key/block`
   style endpoints, or server-side template injection in a `/prompts/test`-style endpoint. Prove
   with a benign bounded probe only, never a destructive or data-modifying payload. Fingerprint the
   database and actual query context before choosing syntax; a wrong-dialect error is not evidence
   that the boundary holds. Prefer paired true/false predicates constrained to one synthetic key row.
   If timing is necessary, first validate the dialect, one-time invocation and statement timeout in
   an authorized fixture: PostgreSQL uses pg_sleep, which returns void and cannot simply follow OR
   as a boolean. Do not use a per-row delay or unbounded query. Without a controlled fixture and known
   bounds, leave the active timing probe under Not covered.
4. **Cross-key, cross-tenant, and budget isolation.** Use two customer-designated test teams and
   synthetic virtual-key records on the customer-owned gateway. Authenticate as test team A and
   request only one protected marker or minimal metadata field from test team B's known canary key;
   never enumerate live team keys or retrieve their credentials, budgets or customer configuration.
   Establish that A lacks the relevant permission; a legitimate cross-team administrator is the
   allowed control. Prefer read-only proof. If a reversible canary write is required, record its
   initial state, use an authorized cleanup path, restore it immediately and verify no new privilege
   or spending capability remains. This is `tenant-isolation-probe` applied to the gateway's control
   plane. If the designated teams, synthetic key or bounded response are unavailable, report the
   limitation under Not covered.
5. **Denial of wallet.** A missing per-caller rate or budget limit is not a class Sleipnir records.
   Do not record that absence with `scanner_record_finding`. If a bounded check shows no ceiling,
   record a closed investigation. If the same request is a class in the catalog, such as an
   authorization failure or an injection, record that class instead.
6. **Control-plane CSRF.** A finding is an attacker's page causing the operator's browser to perform
   a control-plane action with the operator's credentials. A request made as a bot, without that
   browser, is not the finding. Record a closed investigation unless the browser action happens.
   Do not fire a request against a live operator's session.

## In practice

Operational examples to ground the technique, a starting point rather than a fixed list. Send these
only against a customer-owned gateway, with an approved canary, the smallest request, and no live
payload. For isolation tests, both teams and the foreign key below must be designated synthetic
fixtures. Use a test route or response selection that cannot return unrelated live records.

```
# SSRF via a model-routing parameter (owned canary only)        -> server-side request forgery
POST /v1/chat/completions {"model":"m","api_base":"http://<approved-canary>/r","messages":[]}
POST /v1/chat/completions {"model":"m","user_config":{"api_base":"http://<approved-canary>/r"}}

# auth bypass on a management route                             -> broken access control
GET /key/info?key=<DESIGNATED_SYNTHETIC_KEY>  Host: <reconstructed-route-host>
GET /user/info?user_id=<DESIGNATED_SYNTHETIC_USER>  # user and all attached key metadata are canaries
# no bare admin/user-info request; leave Not covered if response selection cannot be bounded

# key-verification injection: first confirm dialect and query shape; return only a synthetic marker
Authorization: Bearer <paired boolean probe limited to the designated synthetic key row>
# adapt true/false predicates to the actual SQL context; no portable sleep expression or per-row delay
POST /prompts/test {"template":"{{7*7}}"}  # evaluation reconnaissance, not a finding by itself

# cross-key / cross-tenant on the control plane                 -> broken access control
GET /key/info?key=<TEST_TEAM_B_SYNTHETIC_KEY>  # authenticate as test team A; read only B's canary metadata
# verify A's policy excludes this read; no live keys, real budgets or key enumeration
```

Describe any upstream credential by role; never capture or keep it.

## Evidence that proves the finding

The exact bounded request and its observed effect, captured by reference, plus the policy or denial
that establishes the boundary. Use `server_side_request_forgery` for an independently forbidden
destination reached; `broken_access_control` for an unauthorized management or test-team canary read;
`executed_injection` for proven server-side SQL or command injection; and `sensitive_data_exposure` for a
protected synthetic disclosure not better explained by those mechanisms. A boolean/timing delta must
be attributable to execution rather than ordinary latency or an error, and arithmetic in an intended
template-test endpoint is not a finding. One root cause is one finding. A missing rate limit is not a
recorded class. Include the designated teams, canary ownership, the caller's permissions and verified
restoration of any changed state. Name the product/version from recon. Record observed refusals as
negative results; leave unsent requests under Not covered. Never store a recovered upstream credential;
describe it by role.

_Source (method only): LiteLLM security advisories, CVE-2026-59823 and CVE-2026-84377 (SSRF via
`user_config` / request-body routing params + credential exfil), CVE-2026-49468 (Host-header auth
bypass), CVE-2026-42208 and CVE-2025-45809 (SQLi in proxy key verification / `/key/block`),
CVE-2026-... OIDC cache-key collision and privilege-escalation-via-config advisories; OWASP LLM Top
10 for LLM Applications 2025 (LLM03 Supply Chain, LLM10 Unbounded Consumption); MITRE ATLAS
AML.T0053 AI Agent Tool Invocation and the cross-site WebSocket-hijack gateway case study._
