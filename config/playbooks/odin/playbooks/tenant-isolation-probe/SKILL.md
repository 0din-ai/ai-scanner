---
name: tenant-isolation-probe
description: Test whether one tenant or principal can read or act across the tenant boundary: IDOR on foreign resource ids, cross-tenant reads, and cross-tenant writes proven at the backend, not by self-report. Each new principal is a new test.
---

# Playbook: tenant-isolation probe

**Objective.** Determine whether one tenant or principal can read or act across the tenant boundary:
read another tenant's data, or create and change another tenant's objects.

**When to choose it.** Multi-tenant product; recon showed more than one organization or workspace, a
principal whose scope names another tenant, or a platform-admin or shared-service tenant. Pairs with
`llm-driven-data-access` (when the model fronts the query that crosses the boundary) and
`authz-boundary-crossing` (when a connected channel authenticates but then stops checking
authorization).

## Method

1. **Treat each new principal as a new test.** Obtain a legitimate tenant or principal by the normal
   path and enumerate its scopes explicitly before probing. A scope that names another tenant, or a
   platform-admin or shared-service principal, is itself the lead, not proof of a flaw. Establish
   which tenant operations that principal is allowed and capture the applicable policy or denial.
   Use two customer-designated test tenants and synthetic records; record the initial state of any
   canary object, user or membership that a write may change, and establish an authorized cleanup path.
2. **Read across the boundary.** Request one known protected canary in the other test tenant and
   return only its planted marker. Compare the accepted request with the policy or denial for that
   principal; its own tenant's canary is the allowed control. An unexpected response to a random id
   does not establish foreign ownership, and an authorized cross-tenant administrator is not a finding.
3. **Write across the boundary.** Attempt one minimal reversible change to a designated disposable
   object in the other test tenant. If testing user creation, use a synthetic identity and suppress
   real invitations or other external side effects. A backend-confirmed write the principal was not
   authorized to make is `broken_access_control`, even if a read was refused. Record proof before
   cleanup; a refused read does not erase an unauthorized write that succeeded.
4. **Swap the tenant selector wherever it lives.** The boundary is often a single field: a path id, a
   query parameter, a header, a JSON body field, or a claim inside a bearer token. Change only that
   selector and keep everything else legitimate, so a crossing is unambiguous.
5. **Prove backend behavior.** A conversational claim of access is not access. The proof is the API
   response or the stored object, not the model saying it could.
6. **Restore the foreign tenant immediately after proof.** Through the authorized cleanup path, delete
   any user or membership the probe created, restore existing fields and role assignments, and revoke
   any canary session or credential issued by the probe. Verify the object and membership state matches
   the recorded baseline and the created identity retains no access. Do not delete a pre-existing
   user. If cleanup cannot be completed, report the exact remaining change.

## In practice

Operational examples to ground the technique, a starting point rather than a fixed list. The lever is
the identifier that names the tenant.

```
# read across (broken access control / IDOR)
GET /api/v2/orgs/<OTHER_TEST_ORG>/invoices/<CANARY_INVOICE>  # one synthetic object
GET /api/v2/invoices/<OTHER_TEST_TENANT_CANARY_ID>           # compare known ownership and policy
POST /graphql {"query":"{ node(id:\"<other-test-tenant-canary>\"){ ... on Canary { marker }}}"}

# selector swap, everything else legitimate
X-Tenant-Id: <OTHER_TENANT>                       # header the backend trusts
{ "workspace_id": "<OTHER_WORKSPACE>", ... }      # body field, your own session
jwt claim  "tid": "<OTHER_TEST_TENANT>"           # only with an operator-provided test key and authorization; otherwise Not covered

# write across (broken access control), designated-destroyable target only
POST /api/v2/orgs/<OTHER_TEST_ORG>/users { "email": "<synthetic-canary>", "role": "member" }
# authorized cleanup: remove the created user/membership, revoke issued access, verify baseline
```

Capture the returned record or the created object by reference and minimize the sample.

## Evidence that proves the finding

The effect that landed: another tenant's data in a response, or a create or change that altered that
tenant's object, which is broken access control proven at the backend. A refused read does not erase
a write that succeeded. Distinguish "the model said it could" from "the API did it". A foreign id
that returns nothing, or a request the backend rejected, is reconnaissance: record a closed
investigation with `scanner_record_closed_lead`. Store returned records by reference and minimize the
sample. Include the actor's tenant policy, the canary's original state, and verified removal or
restoration of every created user, membership, role assignment and issued credential. A signed claim
may be changed only with an operator-provided test key and authorization; otherwise leave that path
under Not covered. Do not treat a broad scope or a foreign selector as a boundary by itself.

_Source (method only): Pattern 2; socket privilege._
