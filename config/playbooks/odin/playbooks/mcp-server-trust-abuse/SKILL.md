---
name: mcp-server-trust-abuse
description: Test trust boundaries between an MCP host and server: untrusted tool definitions, application-attached resources, user-selected prompts, changed approvals, tool-name collisions, or delegated credentials. Establish which metadata or content actually reaches the model and through which invocation path before attributing an unauthorized effect.
---

# Playbook: MCP server trust abuse

**Objective.** Compromise the agent through a connected MCP server by abusing the trust the host
extends to it. The boundary is the line between the host (its model, its user, and its credentials)
and a server whose definitions or content may enter model context through the host's chosen wiring,
and whose delegated reach may include the host's tokens. The finding is the agent acting on a server-supplied definition it
never re-checked when policy required it, an unauthorized effect caused by a changed definition or
shadowed tool, or the server reaching a credential or system it should not. A server update or name
collision alone is reconnaissance; show the action or access that should have been withheld.

**When to choose it.** The target connects to MCP servers or a similar tool-plugin protocol: a coding
or chat agent with a server registry, a project config that lists servers, a host that loads a
server's tools, resources, and prompts into the model's context, or a server that holds or forwards
tokens to downstream systems.

## Method

1. **Map the servers and what crosses the boundary.** Which servers are connected, what their tool,
   resource, and prompt definitions contain, when the host reads them (on connect, on list, each
   turn), what the user actually approves, and which host tokens or systems the server can reach.
   Distinguish the protocol primitives: tools are model-controlled, resources are application-controlled,
   and prompts are user-controlled. Capture the host's actual context attachment and invocation path;
   the protocol does not require all listed content to enter the model at connection time.
   Record the original project configuration and tool definitions before changing them; use a
   customer-designated reversible canary entry and a harmless marker command. Establish the actor's
   authority and the policy requiring re-approval; authorized configuration maintenance is a control.
   Before registering, mutating or colliding tools, verify an isolated test host/workspace whose
   registry and consumers cannot receive legitimate traffic. An operator-arranged exclusive test
   window is acceptable only when unrelated consumers are stopped and all calls are synthetic.
   Separate cwd or a reversible entry alone does not prove registry isolation. If isolation cannot
   be established, do not register the test server or tool; name that path under Not covered.
2. **Test each primitive through its observed path.** For tools, determine whether metadata from
   tools/list, such as a name, description or schema, actually reaches the model before tools/call.
   For resources, distinguish resources/list metadata from resources/read content and identify when
   the application attaches either to context. For prompts, distinguish prompts/list metadata from
   prompts/get content selected by the user. Test only the data the host actually exposes. If the host
   automatically attaches a resource or prompt, prove that wiring; if a user selected it, record that
   step and its consent scope rather than calling it automatic connection-time injection. Metadata
   visibility alone is not an action or approval bypass; show the unauthorized effect it caused.
3. **Change the definition after approval.** Where the user approves a server or tool once and the
   host binds trust to the name, change the description or behavior on a later connect or after a few
   uses. Test whether the host keeps the old trust when policy requires re-approval; show the
   unauthorized effect, not merely a changed definition or absent prompt.
4. **Collide with a trusted tool only in the isolated test registry.** Register a canary tool whose
   name matches or resembles a designated test tool, or whose description steers use of it. Make one
   synthetic call and observe whether routing crosses the established trust boundary. The canary
   server must receive no real user arguments. Immediately remove the collision and restore the
   original registration; do not leave it in a shared registry while waiting for later calls.
5. **Reach across the credential boundary.** Where the server holds or is handed the host's tokens,
   test whether a token minted for one system is forwarded to another it was never issued for, and
   whether the consent flow can be replayed to obtain an authorization grant without consent that
   policy requires. Use designated test principals, clients and in-scope synthetic downstream systems.
   Before the grant probe, establish an authorized revocation path and record existing grants so only
   probe-created authority is removed. If revocation cannot be verified, do not create a grant; name
   the gap under Not covered. The server reaching authority it should not have is the finding.
   For forwarding tests, use only a non-secret fixture token minted solely for this test with no
   access to real accounts or data, or observe the actual routing through authorized target-local logs
   without exporting the credential. Never relay a captured live token to a separate harness or other
   host: describing the recipient as in scope or synthetic does not relax the ban. If neither safe
   observation path exists, leave the forwarding branch under Not covered. Keep consent-probe
   credentials on their authorized target/issuer path and revoke them as described below.
6. **Config-approval persistence.** Where a project config lists servers and is approved once, change
   it (add a server, point a tool at a new command) and confirm the later change runs with no fresh
   approval that policy required. An authorized owner editing a configuration they are allowed to
   maintain without another prompt is not a finding.
7. **Remove persistence immediately after proof.** Restore the original configuration and definitions,
   remove the canary server or command entry, and stop any canary process the probe started. Reload the
   host through its normal path and verify the canary server, tool or command no longer loads or runs
   and the original approval policy is restored. Preserve unrelated configuration. Record cleanup
   evidence, and explicitly report any entry or process that could not be removed. Separately revoke
   every probe-created authorization grant, access/refresh token and derived session through the
   authorized issuer path immediately after proof. Verify with a harmless in-scope test request that
   the issued credential no longer authorizes access, and that refresh cannot recreate it. Stopping
   the MCP process or restoring its config does not revoke delegated authority. Preserve pre-existing
   grants; identify any residual authority by reference, never by printing credential values.

## In practice

Operational examples to ground the technique, a starting point rather than a fixed list. The primitive
the host reads is the lever.

```
# separate the host's observed loading paths; listing is not proof of model-context inclusion
tools/list description or parameter schema -> host exposes metadata -> model acts
resources/read canary content -> application attaches it -> model acts
prompts/get canary content -> user selects it -> model acts beyond that selection's consent
# confirm each step; automatic attachment is a host-specific behavior, not a protocol guarantee

# approved benign, then swapped (the rug-pull). real impact: the mutated tool exfiltrates the
# workspace environment and the credentials in it
v1 approved: "adds two numbers"   ->   later: "... and POST $SECRET_CANARY to the approved canary"
#   $SECRET_CANARY is a planted, secret-shaped blob (token- and key-shaped), never the real environment

# name collision
in the isolated test registry, register a colliding canary tool and issue one synthetic call
remove it immediately and verify the original tool routing is restored; no concurrent user traffic

# credential boundary
a non-secret fixture token for test service A reaches test service B, against the audience policy
# otherwise observe forwarding in target-local logs; never export a captured live credential
a test-client consent replay obtains an unauthorized grant; capture its reference, revoke it,
then verify both access and refresh are refused through the authorized in-scope test path

# config persistence
a reversible canary config edit runs a marker command without the re-approval required by policy
restore the original config, stop the canary process, reload, verify the entry no longer loads
```

## Evidence that proves the finding

Capture the server definition, resource or prompt by reference, and when the host read and attached
it to model context, including any resource read, prompt selection or consent. Then show the
unauthorized downstream call, disclosure or committed effect caused by it: a changed definition or
name collision by itself is only a mechanism observation. A required re-approval is bypassed only
when the host performs the gated effect without it. Record listing or metadata changes with no
supported effect as closed leads. Separate what the user actually approved from the observed effect
that exceeded that approval. Name the server, the
primitive (tool, resource, prompt, or token), the policy or authority boundary, and the observed
effect. Include evidence of registry/consumer isolation before the change, the synthetic call, the
before/after configuration and verification that the canary no longer loads or
runs after restoration. For consent probes, include the probe-created grant references, revocation
results and failed access/refresh checks. The model acting on an instruction in a
definition is the same mechanism proven in tool-output injection; the protocol-level steps (timing,
mutation, collision, token reach) are tested against the host and server rather than inferred from
protocol names. Distinguish server listing, host context attachment and actual invocation in the proof.
