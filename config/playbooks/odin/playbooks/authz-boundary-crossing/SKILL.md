---
name: authz-boundary-crossing
description: Assess an authorized API or real-time channel for missing authentication and per-action authorization after connection setup. Use when recon finds WebSocket, Socket.IO, SignalR, SSE-adjacent command APIs, or direct frontend APIs; test horizontal, vertical, transport-parity, and session-lifecycle boundaries with two controlled principals and synthetic resources.
---

# Playbook: authorization-boundary crossing

## Mission

Determine whether an application authenticates a connection, session, or transport but fails to
authorize the individual resource, room, event, or action performed through it. Prove the backend
effect, not merely that a protocol handshake or message parser accepted input.

The core question is:

> Can principal A cause or observe an effect that policy reserves for principal B, another tenant,
> or a more privileged role?

## Select this playbook only when

Recon confirms at least one of these surfaces:

- a WebSocket endpoint or real-time framework such as Socket.IO or SignalR;
- a negotiate, handshake, polling, upgrade, hub, room, channel, or subscription route;
- a frontend that calls an API directly with resource identifiers or role-sensitive actions;
- the same business action exposed through both HTTP and a real-time transport; or
- a persistent connection whose authorization may become stale after logout, revocation, or a role
  change.

Use `tenant-isolation-probe` when the main objective is broad cross-tenant coverage across many
object types. Use this playbook when the suspected defect is specifically at an endpoint,
connection, room, event, or transport boundary. Use `business-logic-manipulation` when the caller is
authorized to reach the action but can manipulate its economic or policy meaning.

Permissive CORS, an unauthenticated upgrade, a disclosed event name, and an acknowledgement are
reconnaissance signals. None is a finding without a protected read or executed forbidden action.

## Required test fixtures and authorization gates

Before active testing, establish:

1. **Scope:** exact hosts, paths, tenants, transports, and write operations authorized for testing.
2. **Two controlled principals:** A and B, with documented roles and tenant memberships. If only one
   principal is available, horizontal authorization testing is **Not covered** rather than guessed.
3. **Known-owned synthetic resources:** one resource created by A and one by B. Record both IDs and
   expected ownership. A random or nonexistent ID is a negative control, not a substitute for B's
   known-valid ID.
4. **Policy oracle:** UI behavior, API denial, product documentation, or operator-provided policy
   showing what A should and should not be able to read or change.
5. **Reversible proof:** a harmless marker, test-only state change, or synthetic message that can be
   independently verified and removed.
6. **Cleanup path:** how to leave rooms, close sessions, delete synthetic objects/messages, and
   restore modified state.

Do not test an unknown third party's resource, enumerate real customer identifiers, or use captured
credentials outside the target. Stop at the smallest synthetic effect that proves the boundary.

## Phase 1 — inventory the transport and authorization model

Build a surface map from observed traffic and served client code:

| Item | Capture |
|---|---|
| Connection route | scheme, host, path, query, transport, protocol version |
| Authentication | cookie, bearer token, query token, subprotocol, negotiate token, or none |
| Origin handling | allowed and rejected `Origin` values; whether credentials are involved |
| Namespace or hub | namespace, hub, room, channel, topic, group, or subscription identifier |
| Operation vocabulary | client event, hub method, HTTP route, arguments, acknowledgement shape |
| Resource selector | object ID, tenant ID, room name, account ID, or implicit session scope |
| Server effect | response data, broadcast, durable write, job start, or downstream request |
| Lifecycle | connect, authenticate, join, act, leave, logout, revoke, reconnect |

Recover operation names from actual evidence in this order:

1. browser network traffic and captured frames during a normal A-owned action;
2. served JavaScript and source maps when available;
3. framework metadata or negotiate responses; and
4. bounded mutation of an already observed message shape.

Do not brute-force a large event namespace when the client already exposes the supported
vocabulary. Preserve the exact client bundle or frame reference used to derive an event name.

### Protocol interpretation

- A polling error such as `Transport unknown` can fingerprint an engine route, but it does not prove
  that the rejected transport is supported or that authentication is bypassed.
- `101 Switching Protocols` proves an upgrade, not application authorization.
- A Socket.IO Engine.IO open packet, namespace connection, SignalR negotiate token, or event
  acknowledgement proves protocol progress only.
- A finding requires protected data returned to the wrong principal or a forbidden server-side
  effect that actually occurred.

## Phase 2 — establish the authorization matrix

For one observed operation, record the expected and actual result for each applicable cell:

| Caller state | Target | Expected result |
|---|---|---|
| Unauthenticated | public or connection route | Handshake may succeed; protected actions must fail |
| Unauthenticated | A's resource or room | Deny without disclosing protected state |
| Principal A | A's resource or room | Allow according to A's role |
| Principal A | nonexistent random ID | Consistent not-found/denial; use only as a negative control |
| Principal A | B's known-valid resource or room | Deny without read, subscription, broadcast, or write |
| Principal A | privileged action | Deny unless A's documented role permits it |
| Revoked or logged-out A | previously open connection | Reauthorize or terminate before protected actions |

Use B only to create and verify B's synthetic resource. Send the boundary probe as A. Change one
variable at a time—normally only the resource, room, tenant, or action identifier—while preserving
the rest of A's known-good request.

## Phase 3 — execute the applicable hypothesis families

### A. Connection accepted without usable authentication

**Hypothesis:** an unauthenticated client can progress beyond transport setup and perform a
protected application action.

1. Replay the observed connection without each authentication carrier, one at a time.
2. Record the furthest protocol state reached: transport upgrade, framework open, namespace/hub
   connection, room join, event acknowledgement, data delivery, or executed action.
3. Send one harmless, previously observed protected operation against A's synthetic resource while
   unauthenticated.
4. Verify any claimed effect through A's authenticated view or the target's authoritative state.

**Success:** protected data is returned or a protected server-side action executes without the
required authenticated principal. A handshake, open packet, or acknowledgement alone is not
success.

### B. Horizontal resource or room crossing

**Hypothesis:** principal A can read, subscribe to, receive broadcasts from, or modify B's
known-valid synthetic resource.

1. Capture A's successful operation against A's resource.
2. Repeat with a random nonexistent ID to establish error behavior.
3. Repeat as A with only the selector changed to B's known-valid synthetic ID, room, or channel.
4. For a read or subscription, require B's protected synthetic marker in the response or delivered
   event.
5. For a write, use a reversible marker and verify the state from B's authenticated view.
6. Restore B's resource immediately after proof.

**Success:** A receives B's protected marker, joins a B-only delivery stream, or causes a verified
change to B's synthetic resource. Different error wording or an acknowledgement without the effect
is not success.

### C. Vertical action crossing

**Hypothesis:** a lower-privileged principal can invoke an event, hub method, or API action reserved
for a higher role.

1. Observe the privileged operation using an authorized controlled account, or derive the policy
   from an operator-provided specification. Do not obtain it by probing an uncontrolled account.
2. Replay the same operation as A against A's own synthetic resource so tenant crossing is not a
   confounder.
3. Use the smallest reversible privileged effect, such as toggling a test-only flag or starting a
   harmless test job.
4. Verify the result from authoritative state, not from the acknowledgement text.

**Success:** A causes the role-restricted effect despite lacking the required role.

### D. HTTP and real-time policy parity

**Hypothesis:** the HTTP route enforces authorization but the equivalent real-time event does not,
or vice versa.

1. Identify the same business operation on both transports.
2. Run the same A-to-B synthetic-resource test through HTTP and the real-time channel.
3. Preserve caller identity, target ID, operation, and payload so transport is the only meaningful
   variable.
4. Capture the denial on the protected transport and the effect on the vulnerable transport.

**Success:** one transport performs a protected read or action that the equivalent operation and
policy deny on the other. The denial is the baseline; the executed effect is the finding.

### E. Stale authorization on a persistent connection

**Hypothesis:** a connection retains authorization after logout, token revocation, tenant removal,
or role downgrade.

1. Connect as A and perform one permitted synthetic baseline operation.
2. Through the product's normal administrative path, revoke the session or remove the tested role
   or membership.
3. Without reconnecting, repeat the same protected operation on the existing connection.
4. Open a fresh connection with the revoked credential as a control.
5. Restore the controlled account's original state after testing.

**Success:** the existing connection continues to perform a protected effect after the revocation
should have taken effect, while policy or a fresh connection shows that authority is gone.

## Phase 4 — interpret and record the result

Use this decision sequence:

1. **Was protected data returned or a server-side effect executed?** If no, do not record a
   finding.
2. **Was the caller already authorized?** If yes, it is intended capability unless a different
   boundary was crossed.
3. **Does the known-valid B resource behave differently from the random ID?** Use this comparison
   to distinguish an ownership failure from generic parser or existence behavior.
4. **Can the effect be attributed to the tested identifier, role, transport, or lifecycle change?**
   Require a one-variable comparison or equally strong causal evidence.
5. **Which Sleipnir class matches the effect?** Record the boundary failure, not every mechanism:

| Observed effect | Candidate class |
|---|---|
| A reads or changes B's object, room, or tenant resource | `broken_access_control` |
| An unauthenticated, revoked, or misbound session acts as another authority | `session_and_authority` |
| A transport path skips a required business approval or checkpoint | `workflow_bypass` |

Prefer `broken_access_control` for ordinary horizontal or vertical authorization failures. Use
`session_and_authority` when the defect is specifically identity/session binding or stale authority.
Do not record duplicate classes for one underlying effect unless each has a distinct boundary and
independent impact.

## Sleipnir evidence and recording contract

For a positive result, call `scanner_record_finding` while the trace is fresh. Supply:

- `class`, `impact_tier`, and `reach`; never supply severity;
- a `title` and `location` naming the route plus event, hub method, room, or parameter;
- `evidence` referencing the caller identity, A-owned baseline, random-ID control, B-owned probe,
  exact request/frame, response or acknowledgement, and independent verification of the effect;
- `claim`, `impact`, `confidence`, and `effect: observed`;
- `boundary` naming the role, tenant, object owner, or session state that should have stopped A;
- `baseline` containing the observed denial or authoritative policy for that same caller/action;
- `who`: the actor tested and the prerequisites (sign-in, role, tenant relationship, controlled
  input, any victim action). Not a reach word and not `boundary`. Say when the minimum role was not
  verified. At most 500 UTF-16 code units;
- `how`: 1-6 non-empty comparison statements, each at most 400 UTF-16 code units, not a diary; and
- `steps`: 1-8 ordered objects with exactly three strings: `do` (the action), `sent` (the tested
  request), and `got` (the observed result). `sent` and `got` are both empty only for setup, and at
  least one step has both non-empty. Do not invent a response or put a real credential, session,
  or customer record in `who`, `how`, or `steps`.

For `broken_access_control`, use impact tier `I3` for an observed unauthorized protected read or
write and `I4` only when the evidence shows cross-tenant impact or account takeover. Let Sleipnir
derive severity from impact tier and reach.

When the result depends on an earlier finding in the same scan, pass only the returned finding
handle in `chains_from` and explain the dependency in `chain_basis`. Never invent handles or
fingerprints. Minimize evidence and do not include live credentials or real customer records.

Call `scanner_record_closed_lead` after a meaningful test concludes without a reportable effect.
Supply exact `target`, `action`, `attempted`, `observed`, and `why` values covering the surface,
operation, tested matrix cells, results, and reason the boundary held or the hypothesis is exhausted.
Only the Sleipnir lead's closure is durable, so the
lead must record a teammate's concluded negative result. If a required second principal, known-owned
fixture, or authorization is unavailable and no probe was sent, list the branch under **Not
covered** instead of creating a closure.

## Stop conditions

Stop the active branch immediately when:

- one protected synthetic read, subscription, broadcast, or reversible write proves the boundary;
- the next step would enumerate uncontrolled resources or touch real customer data;
- the next step would cause financial impact, destructive modification, persistence, or service
  disruption;
- a test crosses a tenant, role, host, or action not explicitly in scope;
- the target becomes unstable or produces an unexpected production side effect; or
- the evidence cannot distinguish authorization failure from a protocol or parsing difference.

Preserve evidence references, clean up, and move to the next independent boundary.

## Cleanup and completion

Delete synthetic resources and messages, restore changed roles or memberships, leave test rooms,
close test connections, and reverse every marker write. Verify cleanup through authoritative state;
do not rely on a client acknowledgement alone.

This playbook is complete only when:

- every selected matrix cell has a finding, a durable closed lead, or a **Not covered** reason;
- every finding proves a backend read or effect rather than transport acceptance;
- every finding names the denied role, tenant, ownership, or session boundary and its baseline;
- HTTP/realtime differences and connection-lifecycle assumptions are documented; and
- all created state has a verified cleanup result.

_Method references: OWASP API Security Top 10 (API1 Broken Object Level Authorization and API5
Broken Function Level Authorization); CWE-862 Missing Authorization and CWE-863 Incorrect
Authorization; Socket.IO, Engine.IO, SignalR, and WebSocket authorization testing patterns.
References inform the method only and do not expand engagement scope._
