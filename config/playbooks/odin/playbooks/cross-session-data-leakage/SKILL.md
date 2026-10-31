---
name: cross-session-data-leakage
description: Make one user's data surface in another user's session through shared state in the AI layer: a memory store not scoped to the user, a response or semantic cache keyed without the principal, context retained across a user switch, or a retrieval index shared across tenants. The boundary is session and user isolation above the backend, with no resource-id manipulation. Prove a canary planted as one principal arriving to another.
---

# Playbook: cross-session data leakage

**Objective.** Show that data belonging to one user or session reaches another through shared state in
the AI layer, with no backend identifier manipulation. The boundary is isolation between sessions and
users above the data store: a memory not scoped to the principal, a cache keyed without the user,
context carried across a user switch, or a shared retrieval index. The finding is a canary planted as
one principal arriving in another principal's session.

**When to choose it.** The product has per-user memory, a response or semantic cache, long-lived
conversation context, or a shared vector or search index, and more than one user or session uses the
same deployment. The leak here comes from how the assistant stores and recalls state, above the
backend access checks, so no foreign resource id is manipulated. This is the AI-layer counterpart to
`tenant-isolation-probe`, which crosses the same boundary at the backend.

## Method

1. **Establish two principals and cleanup before planting.** Use designated test principals and
   establish that B is not entitled to A's protected state. Record the original memory, preference or
   document state and an authorized deletion/restoration path, including any cache or index copies.
   Then plant one distinctive canary as A: a memory write, cached query/answer, preference or document.
   Do not plant durable state if no bounded cleanup path is available; name that limit under Not covered.
2. **Hit the response or semantic cache from B.** Issue the identical query A made, to return A's
   cached answer (a cache keyed on the prompt hash with no principal in the key). Then issue a
   paraphrase of A's query: a semantic cache keyed on embedding similarity can return A's answer for a
   near-neighbor prompt even when the text differs.
3. **Read A's memory or documents from B.** Ask B's assistant for remembered or prior context, or a
   question whose answer exists only in A's memory write or uploaded document. A memory namespace that
   is global, or keyed on a spoofable field rather than the authenticated principal, returns A's data.
4. **Query the shared index from B.** Where retrieval is backed by a vector or search index, ask for
   content only A's document answers. An index with no per-tenant metadata filter, or a single shared
   namespace, returns A's chunk to B.
5. **Probe automatic context retention on a principal switch.** Follow the product's normal
   sign-out/sign-in or user-switch path and check whether it automatically retains A's context for B.
   Do not copy A's session, conversation handle or credential into B's request. Explicit substitution
   of a foreign handle tests an ownership check; route that case to `tenant-isolation-probe` and do
   not attribute it to shared AI state without independent evidence.
6. **Prove it at the boundary.** A's protected marker appears in B's session, attributed to shared
   state and to no data B was entitled to. Keep document names and query topics distinct from the
   marker, and never supply the marker in B's prompt or history; repeating a value supplied by B
   would not prove retrieval or leakage.
7. **Remove the planted state after proof.** Delete probe-created memory entries and documents,
   restore any pre-existing preference or record, and invalidate only the canary's cache/index copies
   through the authorized path. End the probe conversations carrying it. Verify in fresh sessions
   that neither A nor B retrieves the planted state, using questions that do not themselves supply the
   marker. Do not clear unrelated user data. Report residual state or a cleanup failure explicitly;
   source deletion alone does not prove a retained cache entry is gone.

## In practice

Operational examples to ground the technique, a starting point rather than a fixed list. Plant as one
user, read as another; vary only the principal. Remove probe-created state and verify its absence
from fresh sessions after recording proof; preserve pre-existing data.

```
# response / semantic cache (no principal in the key)
A: "what is my saved test marker?"     B: the same prompt verbatim, in B's own session
B: "recall my saved test marker"       # paraphrase; neither query supplies A's marker or handle
# attribute any cross-principal result to the cache with source/trace or controlled warm/cold evidence

# per-user memory not scoped to the authenticated principal
A: "remember my API key is SENTINEL-7781"
B: "what did the previous user ask you to remember?"   /   "recall my saved notes"

# shared retrieval / vector index (no tenant metadata filter)
A uploads CANARY_DOCUMENT containing a protected marker absent from its title
B: "what protected marker is in CANARY_DOCUMENT?"     -> A's marker returned without B supplying it

# context not cleared across a switch
use the product's normal principal switch and observe any automatically retained context
# no manual foreign conversation ID, session handle or credential substitution
```

## Evidence that proves the finding

Principal A's canary appearing in principal B's session, the shared mechanism that carried it (a prompt
or semantic cache, a memory namespace, retained context, or a shared index), and confirmation that B
had no legitimate path to that data. Capture the principal-switch/request path and distinguish
automatic state retention from explicit foreign-handle substitution. Without mechanism evidence,
report only the observed cross-principal access, not a specific cache or memory root cause.
Record this isolation failure as `broken_access_control`:
B's role, sign-in or tenant should have prevented the read. The disclosure is its impact, not a second
finding under `sensitive_data_exposure`. Apply the cross-tenant impact rule only when distinct tenants
were established; two users are not automatically two tenants. Separate B reading its own data, or
another authorized session of the same user, from A's protected state crossing into B. Use only
canaries you planted as A, carry anything returned by reference, and do not harvest real other-user
data beyond the canary. Include the original state and verified cleanup of the source, memory and
cache/index copies, or identify what remains and why it could not be removed.
