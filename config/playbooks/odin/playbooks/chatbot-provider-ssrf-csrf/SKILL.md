---
name: chatbot-provider-ssrf-csrf
description: Assess the application plumbing around an authorized chat assistant for server-side URL fetching, protected-data egress, unsafe output rendering, and credentialed cross-site requests. Use when recon confirms a URL-consuming tool, auto-rendered model output, or widget state-changing endpoint; require synthetic data and transport-level proof, with an approved canary for off-scope callbacks.
---

# Playbook: chatbot-provider SSRF, egress, and CSRF

## Mission

Determine whether data or requests can cross a trust boundary through the infrastructure surrounding
the assistant. Test four distinct effects: a server-side fetch to a forbidden destination,
protected synthetic data leaving to an unauthorized audience, model output executing in a viewer's
browser, or a cross-site page causing a credentialed state change.

The assistant describing a request, echoing a URL, or producing markup is not a finding. Require
transport evidence or independently verified downstream state.

## Select this playbook only when

Recon confirms at least one application-level surface:

- a tool that fetches, previews, summarizes, imports, validates, or renders a URL;
- remote image, avatar, document, webhook, feed, callback, or attachment ingestion;
- model output automatically rendered as Markdown, HTML, rich cards, or link previews;
- an assistant tool that can post to a caller-supplied destination; or
- widget endpoints that change state using browser credentials.

Use `model-gateway-and-infrastructure` when the controllable destination belongs to model-routing
configuration such as `api_base`, provider selection, or gateway credentials. Use this playbook for
the customer's application, tool executor, chat renderer, and widget backend.

Keep the four claims separate. An approved-canary callback proves outbound fetching, but not SSRF
unless the destination is independently forbidden; it does not prove sensitive-data exposure unless
protected synthetic data crossed the boundary; and it does not prove CSRF unless a victim browser
sent credentials and caused state change.

## Required inputs and authorization gates

Before an active probe, establish:

1. **Scope:** exact hosts, URL consumers, renderers, widget endpoints, identities, and state changes
   approved for testing. The scan's scope is the target plus any destination the operator names in
   the notes, less anything the operator excludes; a later instruction widens it for that
   instruction's work only. Nothing is in scope because the target can reach it, and a destination
   the operator mentions only to exclude it stays out.
2. **Execution identity:** whether the fetch occurs in the server, tool sandbox, browser, extension,
   or operator console.
3. **Approved canary for off-scope callbacks:** an operator-controlled callback origin with private
   logs and a unique marker. Public request bins are prohibited. An explicitly scoped internal
   destination can instead provide direct response or target-side log evidence without a canary.
4. **Synthetic secret:** a unique non-sensitive value placed in a controlled record when testing
   egress. Never substitute live credentials or customer data.
5. **Forbidden-destination oracle:** policy or network design showing which executor destinations or
   schemes should be unreachable.
6. **Controlled browser principal:** a test account and browser session for rendering or CSRF tests.
7. **Cleanup path:** how to remove messages, previews, webhooks, imported documents, and state changes.

For an off-scope request, if no approved canary exists, or the request would carry credentials,
sessions, or customer records, or their forwarding behavior is unknown, do not send it. List that
branch under **Not covered**. A metadata, loopback, or internal destination explicitly authorized
by the scan's scope does not require a canary; the product being forbidden to reach it does not
itself authorize the test. Never collect cloud metadata credentials or real internal records; use
response shape, a harmless test endpoint, or redacted field names as the proof ceiling.

## Phase 1 — map request production and trust boundaries

Run one ordinary in-scope action and capture:

| Surface | What to record |
|---|---|
| Input | field, message, file, metadata, or tool argument accepting the URL |
| Parser | schemes, redirects, hostname normalization, DNS timing, and URL rewriting |
| Executor | server, sandbox, browser, extension, or privileged viewer |
| Request | method, destination, headers, body behavior, redirect behavior, and timing |
| Output | response content, status, preview, error, or downstream tool input |
| Credentials | cookies, authorization headers, service identity, and whether forwarding is intended |
| Renderer | Markdown/HTML handling, preview fetches, sanitization, and user interaction |
| State endpoint | method, content type, anti-CSRF control, origin checks, and SameSite behavior |

Use a unique marker in a harmless in-scope URL or an approved-canary URL to identify the actor and
request shape. Verify the fetch through the executor's response or target-side logs. A callback
from intended public-URL functionality is a control, not a finding. Compare timestamps, source
identity, headers, and target behavior to distinguish server fetches from browser previews,
security scanners, or your own verification request.

## Phase 2 — execute one bounded hypothesis family

### A. Server-side request forgery

**Hypothesis:** a server-side URL consumer can reach a destination or protocol that the public
principal is not authorized to reach.

1. Prove the intended fetch capability with a harmless in-scope URL or an approved canary and a
   fresh marker. Use the executor's response or target-side logs; an external callback is not a
   prerequisite for testing an explicitly scoped internal destination.
2. Establish a forbidden but harmless destination approved for the engagement, preferably an
   operator-owned service reachable only from the executor network.
3. Send one direct URL to that destination and record the executor's response or target-side log.
4. If the direct form is rejected and bypass testing is explicitly authorized, test one
   normalization family at a time: an approved redirect, alternate IP representation, IPv6-mapped
   address, hostname resolution change, or supported alternate scheme.
5. For redirects, keep both redirector and final destination operator-controlled. For DNS tests,
   use an engagement-owned domain and stable logging.
6. Stop after the smallest response marker or target-side hit proves forbidden reach.

**Success:** the product executor reaches the independently forbidden destination and receives a
response or causes a harmless verified effect. A callback to the ordinary public canary, a DNS
lookup alone, a model claim, or a generic timeout is not success.

For cloud metadata assessment, prefer a sandbox fixture that emulates metadata. Only when the
engagement explicitly authorizes the real metadata endpoint may you request a harmless path; record
redacted field names or status, never token values. Do not access IAM credentials.

### B. Protected-data egress through generated output or tools

**Hypothesis:** untrusted content can cause protected data available to the assistant or renderer to
be transmitted to an unauthorized destination.

1. Place a unique synthetic secret in a controlled source the tested principal may cause the system
   to process.
2. Confirm that an unauthorized recipient cannot obtain that value through the ordinary product
   path.
3. Introduce an approved-canary URL through one observed sink: image source, auto-previewed link,
   webhook destination, form/tool post, or imported content.
4. Require the application to assemble the request through its normal flow; do not manually append
   the secret to prove your own URL works.
5. Inspect private canary logs for the exact synthetic value, source actor, and request time.
6. Repeat with the synthetic secret removed to establish the control.

**Success:** the protected synthetic value reaches the approved canary despite the audience
boundary. A marker-only callback proves execution or fetching but not sensitive-data exposure;
echoing the URL or marker in chat proves neither.

### C. Unsafe model-output rendering

**Hypothesis:** model-controlled output executes active content in a controlled viewer's browser.

1. Identify the actual renderer and sanitization boundary; do not infer browser execution from raw
   API output.
2. Render one inert formatting control to confirm the output reaches the chosen sink.
3. Use a harmless, unique execution marker that performs no credentialed action and sends no real
   data. Prefer a controlled DOM/state marker; use the approved canary only if network proof is
   necessary and authorized.
4. Open the output as the controlled test principal in the normal product view.
5. Verify execution in that viewer context and repeat with equivalent escaped text as a control.

**Success:** active content executes in the controlled viewer context or a renderer-generated
request carries the synthetic marker. Raw reflection, inert markup, sanitized rendering, or a
server-side preview is not browser execution.

### D. Cross-site request forgery against widget endpoints

**Hypothesis:** an attacker-controlled origin can cause the controlled victim's browser to perform a
state-changing widget request with ambient credentials and without valid anti-CSRF authorization.

1. Capture one legitimate state-changing request made by the controlled test principal.
2. Record its method, content type, cookies, anti-CSRF token, Origin/Referer behavior, and observable
   state before the request.
3. Build a minimal page on an approved origin that submits the same harmless reversible action
   without reading the response.
4. Load that page in the controlled browser session. Do not replay the request from a command-line
   client as proof of browser behavior.
5. Verify from authoritative state whether the action occurred, then restore it.
6. Run a control without the authenticated browser session or with the expected anti-CSRF value.

**Success:** the cross-site page causes the victim browser to send the credentialed request and the
backend commits the reversible state change. A raw replay, permissive CORS header, rejected request,
or unauthenticated state change is not CSRF.

### E. Redirect and parser-policy inconsistency

**Hypothesis:** validation approves one URL identity but the executor resolves, redirects, or
normalizes it to a different forbidden destination.

1. Document the validator's accepted URL and the executor's final destination using an approved
   canary redirect chain.
2. Change only one parser dimension: redirect hop, encoded host, user-info delimiter, case,
   trailing dot, IPv6 form, or resolution result.
3. Keep each hop operator-controlled and use a unique marker per variant.
4. Compare validation output, final target log, and application response.

**Success:** the accepted input causes the executor to reach a final destination that policy would
have rejected directly. Parser disagreement without a forbidden final reach is a control result.

## Phase 3 — interpret and classify

Use this decision sequence:

1. **Did a request or browser effect actually occur?** If no, do not record a finding.
2. **Which actor made it?** Attribute server, sandbox, browser, preview service, and your own request
   separately.
3. **Was a boundary crossed?** Intended fetching of a public URL is not SSRF; a marker-only callback
   is not protected-data exposure.
4. **Was the state change credentialed and browser-induced?** If not, it is not CSRF.
5. **Can one control reproduce the safe behavior?** Require a direct denial, missing-secret control,
   sanitized output, or unauthenticated browser comparison as appropriate.

Choose the Sleipnir class based on the observed effect:

| Observed effect | Class |
|---|---|
| Executor reaches an independently forbidden network destination | `server_side_request_forgery` |
| Protected synthetic data reaches an unauthorized audience | `sensitive_data_exposure` |
| Active content executes in a viewer's browser | `cross_site_scripting` |
| Cross-site browser request commits state with victim credentials | `cross_site_request_forgery` |
| Planted content causes a tool-backed action beyond its instruction trust | `prompt_injection` |
| Assistant invokes a permitted tool with authority exceeding policy | `excessive_agency` |

Classify the primary effect, not the carrier. Do not label a marker-only callback as sensitive-data
exposure, and do not create duplicate findings unless distinct boundaries and impacts are proven.

### Impact guidance

- `server_side_request_forgery` defaults to `I2`; use `I4` only when cloud-metadata or live
  infrastructure credentials are actually returned. Merely naming or reaching a metadata host does
  not justify the raise.
- `sensitive_data_exposure` uses `I3` when protected data is actually returned. Credentials remain
  `I3`; using them later does not raise the disclosure itself.
- `cross_site_scripting` defaults to `I2`; use `I3` when the script acts as an administrator or
  performs a sensitive action.
- `cross_site_request_forgery` defaults to `I3`, falls to `I2` when the observed effect is limited,
  and reaches `I4` only when the victim-browser action takes over an account or crosses tenants.
- For `prompt_injection`, use the tier of the action or disclosure it caused. `excessive_agency`
  defaults to `I3` and reaches `I4` only when the executed write crosses tenants or returns
  credentials.
- Use `public` reach for paths any unauthenticated or ordinary signed-in user can initiate,
  `privileged` for restricted roles or required victim interaction, and `unknown` when evidence does
  not distinguish them.

## Sleipnir evidence and recording contract

For each positive result, call `scanner_record_finding` while the trace is fresh. Supply:

- `class`, `impact_tier`, and `reach`; never supply severity;
- `title` and `location` naming the URL consumer, renderer, or widget endpoint;
- `evidence` referencing the unique marker, input, actor attribution, transport or target-side log,
  authoritative effect, and comparison control;
- `claim`, `impact`, `confidence`, and `effect: observed`;
- `boundary` naming the forbidden destination, audience, browser execution boundary, or CSRF trust
  boundary;
- `baseline` containing the class-specific protected effect: denied direct destination, retained
  synthetic secret, sanitized rendering, or rejected cross-site state change;
- `who`: the actor tested and the prerequisites (sign-in, role, tenant relationship, controlled
  input, any victim action). Not a reach word and not `boundary`. Say when the minimum role was not
  verified. At most 500 UTF-16 code units;
- `how`: 1-6 non-empty comparison statements, each at most 400 UTF-16 code units, not a diary; and
- `steps`: 1-8 ordered objects with exactly three strings: `do` (the action), `sent` (the tested
  request), and `got` (the observed result). `sent` and `got` are both empty only for setup, and at
  least one step has both non-empty. Do not invent a response or put a real credential, session,
  or customer record in `who`, `how`, or `steps`.

Use only redacted headers and field names. Do not store live tokens, cookies, customer records,
metadata credentials, or real secrets in evidence. If the result depends on an earlier finding,
pass only its returned handle in `chains_from` and state the dependency in `chain_basis`; never
invent a handle or fingerprint.

Call `scanner_record_closed_lead` after a meaningful executed test resolves without a reportable
effect. Populate `target`, `action`, `attempted`, `observed`, and `why` with the exact surface and
discriminator tested. Only the Sleipnir lead's closure is durable, so the lead records teammate
closures. An absent canary for an off-scope callback, uncontrolled browser, unknown credential
forwarding on an off-scope request, or unauthorized destination makes the affected branch **Not
covered**, not closed. Do not mark a scoped internal SSRF test uncovered solely for lacking a canary.

## Stop conditions

Stop immediately when:

- one unique target-side marker, protected synthetic value, controlled execution marker, or
  reversible state change proves the boundary;
- the next step would retrieve credentials, query real internal data, scan ports, or expand network
  reach beyond the approved destination;
- the next request may carry live secrets, sessions, customer records, or unknown attachments;
- browser execution would affect anyone except the controlled principal;
- the next state change is destructive, financial, persistent, or irreversible;
- the target becomes unstable or generates unexpected downstream traffic; or
- request attribution cannot distinguish the application from a scanner or operator action.

## Cleanup and completion

Delete test messages, imported documents, previews, callbacks, webhook registrations, and synthetic
records. Restore each CSRF state change, close controlled sessions, and expire canary identifiers.
Verify cleanup in authoritative state and retain only minimized, redacted evidence.

The playbook is complete only when:

- each selected URL consumer, renderer, or state endpoint has a finding, durable closed lead, or
  **Not covered** reason;
- every finding proves transport or downstream effect and identifies the executing actor;
- SSRF, egress, browser execution, and CSRF claims remain separately classified;
- teammate results and returned finding handles are reconciled by the lead;
- no live secret or uncontrolled third-party data was transmitted; and
- all created state and callback routes have verified cleanup results.

_Method references: OWASP SSRF Prevention and CSRF Prevention Cheat Sheets; OWASP Top 10 for LLM
Applications 2025 LLM02 Sensitive Information Disclosure and LLM05 Improper Output Handling; CWE-918
Server-Side Request Forgery, CWE-79 Cross-site Scripting, and CWE-352 Cross-Site Request Forgery.
References inform the method only and do not expand engagement scope._
