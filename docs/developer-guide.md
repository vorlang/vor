# Vor Compiler — Developer Guide

This document describes the current state of the Vor compiler. It is an internal reference for anyone working on the compiler, including AI coding agents. Update this document as features are added.

Last updated after: critical fixes (soundness, graph extraction, system runtime, dead code cleanup)

## Architecture

Pipeline: `.vor` source → Lexer → Parser → AST → IR (Lowering) → Analysis/Verification → Erlang codegen → BEAM binary

Key files:
- `lib/vor/lexer.ex` — NimbleParsec tokenizer
- `lib/vor/parser.ex` — Recursive descent parser
- `lib/vor/lowering.ex` — AST → IR transformation
- `lib/vor/codegen/erlang.ex` — IR → Erlang abstract format
- `lib/vor/compiler.ex` — Pipeline orchestrator
- `lib/vor/analysis/completeness.ex` — Emit path analysis and handler coverage
- `lib/vor/analysis/protocol_checker.ex` — Protocol conformance validation
- `lib/vor/graph.ex` — State graph extraction
- `lib/vor/verification/safety.ex` — Safety invariant verification

## Agent compilation targets

- Agent with no `state` declaration → gen_server
- Agent with non-enum state fields only (`state count: integer`) → gen_server with state map
- Agent with `state phase: :a | :b | :c` (enum union) → gen_statem
- First enum-typed state field → gen_statem State atom
- Additional state fields → entries in the Data/State map with type defaults (integer→0, atom→nil, map→%{}, list→[], binary→<<>>)
- Parameters and state fields share the same map for both gen_server and gen_statem

## What works in handler bodies

### Expressions
- Arithmetic in emit fields: `remaining: max_requests - current` (operators: +, -, *, /)
- Operand order: `var OP var`, `var OP int`, and `int OP var` all work
- Variable binding from extern calls: `upper = String.upcase(text: T)`
- Variable binding from arithmetic: `doubled = V + V`
- Variable binding from pattern matching: `on {:msg, field: V}`
- Parameter and data field references in emits and extern args: `emit {:r, val: greeting}`

### Conditionals
- If/else: `if current <= max_requests do ... else ... end`
- Nested if/else works: full statement set inside if bodies
- If condition operators: `<=`, `>=`, `==`, `!=`, `>`, `<`
- Boolean logic in if conditions: `if X > 0 and Y > 0 do`

### Guards (on handler patterns)
- Equality: `when phase == :closed`
- Range checks: `when S in 300..699`
- Comparison operators: `when V > threshold`, `when T >= current_term`
- Boolean and/or: `when phase == :proceeding and S in 300..699`

### State management
- `state phase: :a | :b | :c` — the gen_statem State. First enum field.
- `state count: integer` — goes into Data map with default 0.
- `state label: atom` — goes into Data map with default nil.
- `transition phase: :new_state` — changes the gen_statem State atom.
- `transition count: count + 1` — updates Data map field with expression.
- `transition voted_for: C` — updates Data map field with variable.
- Multiple transitions in one handler are collapsed into a single state change with map update.

### Gen_statem call support
- Handlers respond to both `cast` and `call` events.
- Call replies include the emitted value.
- `:gen_statem.call(pid, {:msg, %{field: val}})` returns the emit tuple.

### Timers
- `start_timer`, `cancel_timer`, `restart_timer` from relations — works for gen_statem
- gen_statem state timeouts for liveness monitoring — works

### Local variables
- Binding from pattern match — works
- Binding from extern call — works
- Binding from arithmetic expression — works (`x = a + 1`)

## What works in invariants

### Safety (proven)
- `never(phase == :state and emitted({:msg, _}))` — verified by graph walk
- `never(transition from: :a, to: :b)` — verified by graph walk
- Resilience timeout transitions included in graph and verified

### Liveness (monitored)
- `always(phase != :idle implies eventually(phase == :done))` — runtime via gen_statem state timeouts
- Requires matching resilience handler
- Timeout duration can come from agent parameters

## Extern declarations
- Declared in `extern do ... end` block
- Untrusted by default — try/catch wrapped in generated code
- Proven invariants that depend on extern results produce warnings

## Parameterized agents
- Params declared after agent name: `agent Foo(x: integer, y: binary) do`
- Passed as keyword list to init: `GenServer.start_link(Foo, [x: 10, y: "hi"])`
- Available in handlers, relations, and liveness timeout expressions
- Immutable after init
- Stored in Data map alongside data fields

## Multi-agent systems

### Protocol declarations
- `accepts` — messages this agent can receive
- `emits` — replies to the caller (synchronous)
- `sends` — forwards to connected agents (asynchronous, via Registry)

### System blocks
```vor
system Pipeline do
  agent :source, Source(batch_size: 10)
  agent :sink, Sink()
  connect :source -> :sink
end
```

### Protocol composition checking
The compiler verifies for each `connect :a -> :b`:
- Every `sends` tag in A matches an `accepts` tag in B
- Field names must be identical (type mismatch is a warning)
- Send targets in handlers must reference connected agents
- Dead accepts (no connected sender) produce warnings

### Send codegen
`send :target {:msg, fields}` generates `gen_server:cast` via OTP Registry.
System supervisor starts a Registry and all agents in dependency order.

## Handler completeness checking

### Mandatory else for call handlers
If a handler contains any `emit`, every code path through that handler must reach an emit. Specifically:
- If an `if` block contains an emit, the `else` block is mandatory and must also emit
- A default emit after an if block satisfies this (the if can lack an else if the emit follows it)
- Nested if/else is checked recursively — each level must have complete coverage
- Cast handlers (no emit) are exempt — else is optional

Produces `{:error, %{type: :incomplete_handler}}` on failure.

### Handler coverage for protocol accepts
Every `accepts` declaration in the protocol must have at least one handler with a matching message tag. Guards may restrict which messages are handled, but the base pattern must exist.

Produces `{:error, %{type: :missing_handler}}` on failure.

### Catch-all handler generation
For message tags that have guarded handlers, the compiler automatically generates catch-all clauses:
- Call messages: reply with `{:error, :no_matching_handler}` instead of crashing
- Cast messages: silently ignored (`keep_state_and_data`)

This prevents process crashes when no guard matches at runtime.

### Pattern matching depth
Vor handlers match one level deep: message tag + named fields. Nested destructuring is not supported. To inspect nested data, bind the field and use an extern call:

```vor
on {:msg, entries: E} do
  first = ListHelper.head(list: E)
end
```

## Bidirectional relations

Relations support forward lookup, reverse lookup, and arithmetic inversion.

**Fact-based relations** can be queried from any field:
- Forward: `solve tier(client: C, max: M)` with C bound fills M
- Reverse: `solve tier(client: C, max: 100)` with max bound fills C

**Equation-based relations** are automatically inverted at compile time:
- `relation temp(celsius: C, fahrenheit: F) do F = C * 9 / 5 + 32 end`
- Forward: provide C, get F
- Inverse: provide F, get C (compiler generates C = (F - 32) * 5 / 9)
- Limited to linear arithmetic (+, -, *, /)

## Resilience blocks

Declare what happens when a liveness invariant is violated:

```vor
resilience do
  on_invariant_violation("transaction terminates") ->
    transition phase: :terminated
end
```

Resilience handlers are generated as regular handler clauses and included in the state graph. The safety verifier checks them.

## Transition ordering

Transitions are applied before emits in the same handler. An emit after a transition reads the post-transition state.

## Guard asymmetry

Gen_statem handlers support full guard expressions: ==, in, >, <, >=, <=, and/or.
Gen_server handlers only support equality guards: `when field == :atom`.
For gen_server agents, use if/else in the handler body for comparisons.

## Invariant verification scope

Safety invariants tagged `proven` are verified by walking the state transition graph. The verifier currently supports:
- `never(phase == :state and emitted({:tag, _}))` — no emit of a message type in a given state
- `never(transition from: :a, to: :b)` — no direct transition between two states

Invariant bodies that use unsupported constructs will produce a compile error when tagged `proven`. Change to `monitored` for properties the verifier cannot yet check.

## TLA+ specifications

The `tla/` directory contains TLA+ specs for the compiler's most critical
modules:

- `VorSafetyVerifier.tla` — correctness of safety invariant verification
- `VorGraphExtraction.tla` — correctness of state graph extraction

If you modify `lib/vor/verification/safety.ex` or `lib/vor/graph.ex`,
review the corresponding TLA+ spec to ensure the algorithm still matches.
Run TLC to verify if you have the TLA+ tools installed.

These specs verify the algorithm, not the Elixir code directly. They
define the contract; the Elixir code must satisfy it.

## Known limitations

1. No list or collection operations native to the language — use extern calls
2. No string operations native to the language — use extern calls
3. No explicit default values for data fields (`state x: integer = 5`) — uses implicit type defaults
4. No pattern matching on extern return values beyond simple comparison
5. No `match`/`case` expressions — only if/else
6. No nested pattern matching in handler patterns — match tag + top-level fields only, use externs for deeper destructuring
7. No guard coverage analysis (whether guards partition the input space) — catch-all handlers cover this at runtime

## Known design debt

### Atom interning

The lexer and lowering phases use `String.to_atom/1` on source-derived identifiers. On the BEAM, atoms are not garbage collected, so compiling large or untrusted source files can grow the atom table permanently. This is acceptable for the current prototype stage but must be addressed before the compiler runs in a long-lived service or accepts untrusted input.

Future fix: keep source names as binaries through lexer/parser/lowering, convert to atoms only at codegen for the final Erlang abstract format.
