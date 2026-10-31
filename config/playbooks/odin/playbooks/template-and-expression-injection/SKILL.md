---
name: template-and-expression-injection
description: Find where the agent framework evaluates attacker input as a template or expression rather than treating it as data: a prompt template rendered with user or tool values, a server-side template engine, an expression or formula language, or a format string. The finding is evaluation reaching other variables, secrets, or code. Prove evaluation with a benign probe rather than an echo.
---

# Playbook: template and expression injection

**Objective.** Show that the agent's own framework evaluates input the attacker controls as a template
or expression instead of holding it as data, so the input reaches variables, secrets, or code it
should not. The boundary is evaluation versus data: a prompt template rendered with user or tool
values, a server-side template engine, an expression or formula language, or a format string. The
evaluation result establishes the mechanism; a reportable finding additionally needs an observed
boundary-crossing effect matching one of the scanner's published finding classes.

**When to choose it.** Recon shows input is rendered rather than only read: a prompt assembled from
user fields or retrieved values, a reporting or calculation tool that takes an expression or formula,
a notification or document built from a template, or a query the agent assembles from input. This is
the application's own template layer, above the host shell and before the model's output handling.

## Method

1. **Find every place input is rendered.** Three families carry this. A prompt template the agent
   framework interpolates with user or tool values is the model-specific flavor, where your text lands
   inside the system or tool-call template. A server-side template engine builds a message, document,
   or page (Jinja2, Nunjucks, Twig, Freemarker, Velocity, Thymeleaf, Handlebars, ERB, Mako, Smarty).
   An expression or formula language is evaluated by a tool (Spring SpEL, OGNL, MVEL, JEXL, CEL, or a
   spreadsheet or reporting formula). If the sink stores a formula or template, first establish a
   customer-designated isolated disposable artifact, its original state, and an authorized restore or
   deletion path. Disable background/automatic recalculation and unrelated readers before planting a
   fetch formula; allow only one controlled evaluation. Without those controls, leave the stored
   external-fetch branch under Not covered.
2. **Probe for evaluation with a benign marker.** Send an expression whose evaluated result differs
   from its literal text, matched to the engine's syntax. On a model surface the model computes
   arithmetic itself, so a computed value in the model's prose is reconnaissance, not proof: the value
   has to come from the framework path (a rendered template, a tool result, or a backend response) for
   the evaluation to be established.
3. **Identify the engine and embedding context.** Delimiters such as `{{ }}`, `${ }`, `#{ }`,
   `<%= %>` and `@( )` narrow a family, not a unique engine. Confirm an engine-specific variable,
   built-in helper or bounded expression and the context that processes it before choosing another
   probe. A literal result or parser error from the wrong syntax does not rule out evaluation.
4. **Read only a named protected synthetic value.** From a confirmed evaluation, request a
   customer-planted configuration or template variable with an inert value and a known audience policy.
   Do not enumerate environment variables, configuration objects or template globals, or read an
   arbitrary secret merely because access is read-only. If no such bounded fixture exists, leave
   context access as an untested escalation under Not covered. Name potential command, file or
   environment access without probing those live resources or claiming the escalation was demonstrated. Native printf-style probes require a customer-designated
   isolated fixture with known, correctly typed variadic arguments, only synthetic values and crash
   containment. Missing or mismatched arguments cause undefined behavior even for nominally read-only
   conversions. Do not probe arbitrary native format sinks on a live service; without the fixture,
   leave that path under Not covered.
5. **Separate evaluation from a reportable effect.** A constant arithmetic or helper result is
   reconnaissance even when it establishes unintended template evaluation. Identify a bounded,
   authorized proof of a supported effect, such as a protected synthetic variable returned to a caller
   who should not receive it. Keep the probes benign and read only; do not execute a command merely
   to force a classification. If no supported effect can be shown safely, record the observed
   evaluation as a closed lead and the untested escalation as a limitation, not a confirmed finding.
6. **Remove stored expressions immediately after the first evaluation.** Restore the original cell,
   report or template, or delete the disposable artifact through the authorized path. Remove
   probe-created cached/indexed copies and queued refreshes, and verify the expression cannot run on
   a later open or recalculation. Keep unrelated state intact and report any remaining formula or
   failed cleanup explicitly. Do this even when the evaluation was only reconnaissance.

## In practice

Operational examples to ground the technique, a starting point rather than a fixed list. Match the
probe to the engine and its embedding context. Evaluation fingerprints the mechanism; it is not
by itself a reportable vulnerability class. Use a protected synthetic value for any disclosure proof. Spring's
standard expression-template context uses `#{...}`; `${...}` in Spring property configuration is a
placeholder. Thymeleaf's Spring dialect can evaluate SpringEL inside `${...}`, and custom parser
contexts may choose other delimiters. Identify the actual context rather than treating a delimiter as
universal. Use a bounded constant result for the method-call probe, not an environment dump.

```
# does it evaluate? Result from the framework path, not model prose
{{7*7}}                         Jinja2, Nunjucks, Twig, Pebble: 49
{{#if true}}CANARY{{/if}}         Handlebars built-in helper: CANARY, not arithmetic
${7*7}                          Freemarker, JSP EL: 49 in an expression-processing context
th:text="${7*7}"                 Thymeleaf processed element attribute: text becomes 49
#{7*7}                          default Spring SpEL template context, JSF expression context: 49
<%= 7*7 %>                      ERB, EJS: 49
@(7*7)                          Razor explicit output expression: 49
# Razor @{ ... } is a code block, not an arithmetic output expression
# Do not infer an engine from a delimiter shared by several implementations.

# fingerprint, then reach context read only (name the escape, do not fire it)
{{protected_canary}}                             Jinja2: designated synthetic context value; establish caller is denied it
#{T(java.lang.Math).abs(-7)}                       default Spring SpEL template context; benign constant result
<#assign x="freemarker.template.utility.Execute">  the Freemarker RCE class, named only

# the agent-framework prompt template: your field lands inside the template
close the surrounding block, then reference a designated protected synthetic variable

# expression / formula tools
=1+1                               a formula tool returning 2 is ordinary evaluation, not a finding
=IMPORTXML("http://CANARY","/")    =WEBSERVICE("http://CANARY")   only the operator-approved canary
# isolated disposable artifact, automatic refresh disabled, one evaluation, then restore/delete and verify
=HYPERLINK("http://CANARY","x")    clickable output alone proves no disclosure
# a supported fetch to an allowed destination is a control, not SSRF; do not fire legacy DDE commands

# native formatting: only an isolated fixture with a known unsigned-int canary argument
# literal "marker=%x" versus evaluated formatting of that synthetic argument; never missing arguments
# no arbitrary register/stack reads, %n writes, mismatched types or production crash probes

# higher-level formatting: only a designated protected synthetic fixture value
{fixture.protected_marker}
```

## Evidence that proves the finding

Capture the rendered template, tool result or backend response that establishes the evaluation
path, tied to the exact field, engine and embedding context. Model-computed prose or an echoed string
cannot establish that path. An intended formula field is normal behavior; unintended arithmetic
shows an evaluation primitive but does not alone meet this scanner's finding bar.

Record only a supported observed effect: `sensitive_data_exposure` when a protected synthetic value
reaches a caller or audience that should not receive it; `broken_access_control` when the demonstrated
root cause is a role or tenant check failing; or `executed_injection` when a server-side SQL or
command sink actually executes injected input, not inferred from arithmetic or a class name.
Prompt-driven invocation of an intended local/sandbox tool instead requires the applicable
`prompt_injection`, `workflow_bypass` or `excessive_agency` boundary and observed effect.
An independently forbidden fetch must satisfy `server_side_request_forgery`'s destination and response
bar. Use the class whose effect and boundary are proven, not a mechanism label such as template
injection or remote code execution, and keep one root cause as one finding. This playbook does not
authorize dangerous execution to obtain proof. If only benign evaluation was observed, record a
closed lead with that evidence and the remaining limitation. Carry any returned sensitive material
by reference, stop at sufficient bounded proof, and do not claim untested escalation. Include the
original artifact state and verification that stored expressions and queued refreshes were removed.
