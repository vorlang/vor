# Vor Compiler — Developer Guide

This document describes the current state of the Vor compiler. It is an internal reference for anyone working on the compiler, including AI coding agents. Update this document as features are added.

Last updated after: Multi-agent model checking (Phase 3: quantifiers + named agent refs + symmetry reduction), internal type tracking, extern proven boundary enforcement, native Raft majority, 349+ tests

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
- `lib/vor/gleam/interface.ex` — Gleam package-interface.json parser
- `lib/vor/gleam/validator.ex` — Gleam type boundary validation
- `lib/vor/type_env.ex` — Type environment for handler body type tracking
- `lib/vor/explorer.ex` — Multi-agent product state exploration (entry point + BFS)
- `lib/vor/explorer/product_state.ex` — Product state representation
- `lib/vor/explorer/simulator.ex` — IR handler action interpreter
- `lib/vor/explorer/successor.ex` — Successor state computation
- `lib/vor/explorer/invariant.ex` — System-level invariant evaluation
- `lib/mix/tasks/vor.check.ex` — Mix task for multi-agent model checking

## Agent compilation targets

- Agent with no `state` declaration → gen_server
- Agent with non-enum state fields only (`state count: integer`) → gen_server with state map
- Agent with `state phase: :a | :b | :c` (enum union) → gen_statem
- First enum-typed state field → gen_statem State atom
- Additional state fields → entries in the Data/State map with type defaults (integer→0, atom→nil, map→%{}, list→[], binary→<<>>)
- Parameters and state fields share the same map for both gen_server and gen_statem

## Named agent registration

Agents accept an optional `name` in the args keyword list:

```elixir
GenServer.start_link(mod, [param: value, name: {:via, Registry, {MyReg, :my_name}}])
```

If `name` is present, the generated `start_link` passes it to `GenServer.start_link/3` or `:gen_statem.start_link/4`. If absent, the agent starts anonymously (backward compatible). This enables multiple instances of the same agent type with different names — used for vnode sharding and similar patterns.

System blocks handle naming automatically via the Registry.

## Init handlers

`on :init do ... end` runs once during agent startup, before the agent accepts messages.

```vor
on :init do
  persisted = VorDB.Storage.load(node_id: node_id)
  transition store: persisted
end
```

Supports: extern calls, variable bindings, transitions, if/else, map/list operations, parameter references.

Does NOT support: emit, send, broadcast (no caller, agent not yet registered). These produce a compile error.

Only one `on :init` per agent. Extern failures in init are caught — state fields keep their defaults. Init handler body runs after parameter extraction and state field default initialization, before `every` timers start.

## What works in handler bodies

### Expressions
- Arithmetic: `remaining: max_requests - current` (operators: +, -, *, /)
- Operand order: `var OP var`, `var OP int`, and `int OP var` all work
- Variable binding from extern calls: `upper = String.upcase(text: T)`
- Variable binding from arithmetic: `doubled = V + V`
- Variable binding from pattern matching: `on {:msg, field: V}`
- Parameter and data field references in emits and extern args
- Min/max: `smaller = min(a, b)`, `larger = max(a, b)`
- Atom literals: `:value`, `:key`, `:not_found`, `nil` — valid in all expression positions
- Noop: `noop` — explicit no-operation statement

### Map operations

Native map operations for state fields and variables of type map:

- `map_get(map, key, default)` — get value by key, or default if missing
- `map_put(map, key, value)` — set a key-value pair, returns new map
- `map_has(map, key)` — returns `:true` or `:false`
- `map_delete(map, key)` — remove a key, returns new map
- `map_size(map)` — number of entries
- `map_sum(map)` — sum of all values (assumes integer values)
- `map_merge(map1, map2, strategy)` — merge two maps with conflict resolution

All operations work on state fields AND local variables. Atom literals work in key and default positions: `map_get(entry, :value, nil)`.

### Map merge strategies

- `:max` — keep the larger value per key (for G-Counter merge)
- `:min` — keep the smaller value per key
- `:sum` — add values per key
- `:replace` — second map wins
- `:lww` — Last-Writer-Wins. Values must be maps with `:timestamp` (integer) and `:node_id` (atom). Keeps the entry with the higher timestamp; ties broken by node_id

### List operations

Native list operations for state fields and variables of type list:

- `list_head(list)` — first element, or `:none` if empty
- `list_tail(list)` — all elements except the first, or `[]` if empty
- `list_append(list, value)` — new list with value added at the end
- `list_prepend(list, value)` — new list with value added at the front (O(1))
- `list_length(list)` — number of elements
- `list_empty(list)` — `:true` or `:false`

All operations handle empty lists safely — no crashes on empty input. All operations work on state fields AND local variables.

### Conditionals
- If/else: `if current <= max_requests do ... else ... end`
- Nested if/else works: full statement set inside if bodies
- If condition operators: `<=`, `>=`, `==`, `!=`, `>`, `<`
- Boolean logic in if conditions: `if X > 0 and Y > 0 do`
- Variables bound inside an if block are visible to subsequent statements in the same block (including emit, send, transition)
- Variables in one branch are NOT visible in the other branch or after the if/else block
- All extern types (Elixir, Erlang, Gleam) work inside if blocks

### Guards (on handler patterns)
- Equality: `when phase == :closed`
- Range checks: `when S in 300..699`
- Comparison operators: `when V > threshold`, `when T >= current_term`
- Boolean and/or: `when phase == :proceeding and S in 300..699`

### State management
- `state phase: :a | :b | :c` — the gen_statem State. First enum field.
- `state count: integer` — goes into Data map with default 0.
- `state label: atom` — goes into Data map with default nil.
- `state store: map` — goes into Data map with default %{}.
- `state items: list` — goes into Data map with default [].
- `transition phase: :new_state` — changes the gen_statem State atom.
- `transition count: count + 1` — updates Data map field with expression.
- `transition voted_for: C` — updates Data map field with variable.
- Multiple transitions in one handler are collapsed into a single state change with map update.

### Transition ordering and data variable threading

The handler body is compiled as a sequential chain. Each statement sees the results of all previous statements:

- Transitions update the data variable: after `transition count: count + 1`, subsequent references to `count` see the post-transition value
- This applies to extern call arguments, emit field values, send/broadcast field values, and subsequent transitions
- Variable bindings from earlier statements are visible to later statements, including inside if blocks

### Gen_statem call support
- Handlers respond to both `cast` and `call` events.
- Call replies include the emitted value.
- `:gen_statem.call(pid, {:msg, %{field: val}})` returns the emit tuple.

### Periodic timers
- `every interval_ms do ... end` — periodic execution
- Interval can be a literal integer or a parameter reference
- Body supports the same statements as handler bodies: transitions, extern calls, broadcast, variable bindings
- Generates `erlang:send_after` in init and re-arms after each execution
- Timers start after `on :init` handler completes

## Internal type tracking

The compiler propagates types through handler body expressions and reports diagnostics for type-incompatible operations.

### Type sources
- State field declarations: `state count: integer` → count is `integer`
- Parameter declarations: types declared in agent parameters
- Built-in operation results: `map_put` returns `map`, `list_length` returns `integer`, etc.
- Gleam extern return types: validated against `package-interface.json`
- Elixir/Erlang extern return types: always `term`
- Message pattern variables: always `term` (caller could send anything)

### Diagnostic levels
- **Error** (blocks compilation): guaranteed crash — e.g., `store + 1` where `store` is `map`, `map_get(count, :key, 0)` where `count` is `integer`
- **Warning** (compiles): likely problem — e.g., assigning `map` result to `integer` field via transition
- **No diagnostic**: any operation on `term` — the developer may know more than the compiler

### Key rules
- `term` is the escape hatch — operations on `term` produce no diagnostics
- Declaring extern return type as `:: term` opts out of type tracking for that value
- Gleam extern return types flow through handler body when interface is loaded
- If/else branches are tracked independently — diagnostics from both branches collected

## What works in invariants

### Safety (proven)
- `never(phase == :state and emitted({:msg, _}))` — verified by graph walk
- `never(transition from: :a, to: :b)` — verified by graph walk
- Resilience timeout transitions included in graph and verified
- Proven invariants cannot depend on extern results (see Extern Declarations)

### Liveness (monitored)
- `always(phase != :idle implies eventually(phase == :done))` — runtime via gen_statem state timeouts
- Requires matching resilience handler
- Timeout duration can come from agent parameters

### System-level safety (proven via model checking)
- `never(count(agents where FIELD == VALUE) > N)` — verified by product state exploration
- Checked via `mix vor.check`, not during `mix compile`
- See Multi-Agent Model Checking section below

## Extern declarations

Three types of extern blocks:

### Elixir externs
```vor
extern do
  MyApp.Storage.save(key: atom, value: map) :: atom
  Vor.TestHelpers.Echo.reflect(value: term) :: term
end
```
Generates `'Elixir.MyApp.Storage':save(Key, Value)`.

### Erlang externs
```vor
extern do
  Erlang.erlang.system_time(unit: atom) :: integer
  Erlang.lists.sort(list: list) :: list
end
```
Generates `erlang:system_time(Unit)` — raw Erlang module atom, no `Elixir.` prefix.

### Gleam externs
```vor
extern gleam do
  vordb/counter.empty() :: term
  vordb/counter.increment(counter: term, node_id: binary, amount: integer) :: term
  vordb/counter.value(counter: term) :: integer
  vordb/counter.merge_stores(local: map, remote: map) :: map
  vordb/or_set.empty() :: term
  vordb/or_set.add_element(state: term, element: binary, tag: term) :: term
end
```
Slash-separated module paths map to `@`-separated BEAM atoms: `vordb/counter` → `'vordb@counter'`. Deep paths work: `vordb/storage/rocks` → `'vordb@storage@rocks'`.

### Keyword parameter names
Vor keywords (`state`, `protocol`, `transition`, `emit`, `broadcast`, `agent`, `every`, etc.) are accepted as parameter names in extern declarations. Foreign functions can use any identifier as a parameter name.

### Extern trust boundary

All extern calls are:
- Wrapped in try/catch — failures don't crash the agent
- Untrusted by default — the compiler cannot verify what they return

**Proven invariants cannot depend on extern results.** If a handler path that could violate a `proven` invariant contains a conditional whose condition depends on an extern call result, and the prohibited emit/transition is inside that conditional, compilation fails. The verifier tracks which variables are tainted by extern call results and checks whether prohibited emits sit behind extern-dependent conditions.

This is path-precise: externs whose results are only used for transitions, used unconditionally before a non-prohibited emit, or sit in a handler whose state isn't covered by the invariant are fine.

To resolve a triggered error:
- Remove the extern dependency from the conditional
- Change the invariant from `proven` to `monitored`
- Restructure the handler so the prohibited emit is unreachable regardless of extern results

### Gleam type boundary validation

When a `package-interface.json` file is available (generated by `gleam export package-interface`), the Vor compiler validates Gleam extern declarations:

- Function exists in the declared module
- Parameter count (arity) matches
- Parameter types are compatible (using type mapping)
- Return type is compatible

Type mapping:

| Gleam type | Vor type | Compatibility |
|---|---|---|
| `Int` | `integer` | Exact match |
| `String` | `binary` | Exact match |
| `Bool` | `atom` | Compatible |
| `List(a)` | `list` | Compatible |
| `Dict(k, v)` | `map` | Compatible |
| `Nil` | `atom` | Compatible |
| `Result(a, e)` | `term` | Compatible |
| Custom types | `term` | Compatible |
| Any | `term` | Always compatible (opt-out) |

Declaring `:: term` opts out of return type validation for that extern. Validation is optional — if no interface file is found, compilation proceeds without type checks.

Build sequence:
```bash
gleam build                           # compile Gleam modules
gleam export package-interface        # generate type metadata
mix compile                           # Vor reads JSON, validates, compiles
```

## Parameterized agents
- Params declared after agent name: `agent Foo(x: integer, y: binary) do`
- Passed as keyword list to init: `GenServer.start_link(Foo, [x: 10, y: "hi"])`
- Available in handlers, relations, liveness timeout expressions, and init handlers
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

### Broadcast

`broadcast {:msg, fields}` sends a message to all agents this agent has outbound connections to in the system block.

- Always asynchronous (cast)
- Works alongside `emit` (reply) and `send :target` (directed) in the same handler
- Works in resilience handlers, if/else bodies, and every blocks
- Requires a system block — compile error if used in a standalone agent
- Generated code iterates `__vor_connections__` and sends via the registry
- Gracefully handles missing peers (skips if not found in registry)

## Multi-agent model checking

### Overview

System blocks can declare system-level safety invariants. These are verified by product state exploration via `mix vor.check` — NOT during standard `mix compile`.

```vor
system RaftCluster do
  agent :n1, RaftNode(node_id: :n1, cluster_size: 3)
  agent :n2, RaftNode(node_id: :n2, cluster_size: 3)
  agent :n3, RaftNode(node_id: :n3, cluster_size: 3)

  connect :n1 -> :n2
  connect :n1 -> :n3
  connect :n2 -> :n1
  connect :n2 -> :n3
  connect :n3 -> :n1
  connect :n3 -> :n2

  safety "at most one leader" proven do
    never(count(agents where role == :leader) > 1)
  end
end
```

### Execution

```bash
mix compile              # parses system invariants, does NOT run exploration
mix vor.check            # runs multi-agent exploration
mix vor.check --depth 30 # custom depth bound
mix vor.check --max-states 200000  # custom state count bound
```

### How it works

1. Constructs initial product state (all agents in initial states, no pending messages)
2. BFS explores successor states by:
   - Delivering pending messages to recipients (all orderings explored)
   - Protocol-driven external events (any `accepts` message from outside the system)
   - Liveness timeout firings (resilience handlers)
3. At each reachable product state, checks all system-level invariants
4. If violation found: reports counterexample trace (exact message sequence)
5. If state space exhausted with no violation: reports proven
6. If bounds exceeded: reports bounded verification (honest, not proven)

### Key design decisions

- **Simulator interprets IR directly** — no separate transition table. The simulator walks `IR.Handler.actions` to compute state changes and outgoing messages. Trade-off: must handle every IR action shape; unsupported actions become no-ops (conservative).
- **`:unknown` propagation** — extern results are `:unknown`. Arithmetic, comparisons, and value references that touch `:unknown` propagate it. Conditionals on `:unknown` fan out into both branches (conservative over-approximation).
- **State-change-only exploration** — successors that don't change any agent state or pending messages are discarded immediately. Deduplication via product state fingerprint (sorted pending messages).
- **Fingerprint sorts pending messages** — collapses message ordering between distinct sender/receiver pairs, matching BEAM delivery semantics.

### Invariant syntax (Phase 1)

```vor
safety "name" proven do
  never(count(agents where FIELD OP VALUE) COMP N)
end
```

- `FIELD` — state field name declared in agent type
- `OP` — `==` or `!=`
- `VALUE` — atom literal
- `COMP` — `>`, `>=`, `==`, `<`, `<=`
- `N` — integer literal

### Counterexample traces

When a violation is found, the trace shows each step: which message was delivered to which agent, the resulting state of all agents, and any pending messages. The developer can walk the trace to understand exactly how the violating state was reached.

### Bounded verification

If depth or state count bounds are exceeded before exhaustive exploration, the explorer reports "bounded verification passed" — it never claims "proven" without exploring the complete reachable state space. The developer can increase bounds via `--depth`, `--max-states`, or `--integer-bound`.

### State abstraction (Phase 2)

`Vor.Explorer.Relevance` computes which state fields are *relevant* for each
system-level invariant before BFS starts. A field is relevant when it is
referenced directly in the invariant body OR when it appears in a guard or
conditional that gates a transition to an already-relevant field
(transitive closure with local-binding propagation through `var = expr`).

Irrelevant state fields are masked with the symbolic value `:abstracted`
after every successor. The simulator treats `:abstracted` exactly like
`:unknown`: opaque to arithmetic and comparisons, fans conditionals into
both branches. This is sound — if the invariant holds for ALL possible
values of the abstracted fields, it holds for the real values.

Parameters are immutable after init. Relevance separates them from tracked
state: their values are still read by the simulator (they appear concretely
in the agent state map) but they are not state-space dimensions, so they
don't bloat the visited set.

### Integer saturation

Tracked integer fields can otherwise grow unboundedly (`vote_count`,
`current_term`, etc.). After every successor the explorer caps tracked
integers to `[0, integer_bound]` (default 3, `--integer-bound N` to
override). This is standard bounded model checking: bugs typically manifest
within small concrete values, and saturation forces convergence so the BFS
can terminate.

### Bounded message queue

Pending messages can also accumulate without bound — broadcasts and chained
sends grow the buffer faster than deliveries shrink it. The explorer caps
the queue at `max_queue` (default 10, `--max-queue N` to override) by
truncating surplus outgoing messages from the tail of the new queue. This
is the lossy-network model: at saturation new sends are silently dropped
rather than refusing the delivery. Combined with state abstraction and
integer saturation, this lets Raft reach `:proven` in 8008 states at
depth 10.

### Quantified invariants (Phase 3)

System-level safety invariants accept three additional shapes alongside
`never(count(...))`:

```vor
%% exists pair: at least two distinct agents satisfying both clauses
safety "no two holders" proven do
  never(exists A, B where A.phase == :held and B.phase == :held)
end

%% exists pair with cross-agent comparison
safety "leaders agree on term" proven do
  never(exists A, B where A.role == :leader and B.role == :leader
    and A.current_term != B.current_term)
end

%% exists single
safety "someone is leader" proven do
  exists A where A.role == :leader
end

%% for_all (unqualified field references)
safety "modes are valid" proven do
  for_all agents, mode == :idle or mode == :active
end

%% named agent reference
safety "n1 stays follower" proven do
  never(n1.role == :leader)
end
```

The evaluator (`Vor.Explorer.Invariant`) walks an operand-resolution model:
- `{:agent_field, var, field}` resolves against quantifier bindings
- `{:named_agent_field, name, field}` resolves against the product state
  by instance name
- `{:field, name}` resolves against the current `for_all` binding

`Vor.Explorer.Relevance.invariant_fields/1` extracts referenced fields from
all of these so abstraction stays sound under the new shapes.

`exists` and `for_all` are recognised **positionally** inside system
invariant bodies — they are NOT reserved keywords, so existing code that
uses them as variable names (e.g. `exists = map_has(data, :key)`) continues
to compile.

### Symmetry reduction (Phase 3)

`Vor.Explorer.Symmetry` automatically detects homogeneous fully-symmetric
systems and applies symmetry reduction. A run is symmetry-eligible when:

1. Every system instance shares the same agent type, AND
2. Every instance has the same `(outbound, inbound)` connection counts
   (covers fully-connected meshes and other symmetric topologies), AND
3. No active invariant references a specific named agent (any
   `{:named_agent_field, _, _}` term disables reduction).

When enabled, the BFS deduplicates against a canonical fingerprint that
sorts the agent state list and strips sender/receiver identity from
pending messages. For three identical Raft nodes the maximum theoretical
reduction is 3! = 6×; in practice the message canonicalization adds a bit
more, so Raft now reaches `:proven` in **1001 states** (vs 8008 without
symmetry — about 8× reduction).

`mix vor.check` prints the result line:

```
Symmetry: enabled (3 identical agents, 6× reduction)
```

Use `--no-symmetry` to force the explorer to keep agent identities
distinct (useful for sanity checking that a proof doesn't accidentally
rely on the reduction).

`mix vor.check` prints the per-run abstraction summary alongside the
result:

```
Checking examples/raft_cluster.vor...
    Tracked fields:    current_term, role, vote_count
    Abstracted fields: commit_index, log, voted_for
    Integer bound:     3
  ~ Bounded verification (5000 states, depth 9)
```

Phase-2 modules:
- `lib/vor/explorer/relevance.ex` — relevance analysis
- `lib/vor/explorer/product_state.ex` — `abstract/2`, `abstract_agent_state/2`, `saturate_integers/3`
- `lib/vor/explorer/simulator.ex` — `:abstracted` reads return `:unknown`
- `lib/vor/explorer/successor.ex` — post-process abstraction + saturation
- `lib/vor/explorer.ex` — wires relevance through `verify_system/4` and stats

## Handler completeness checking

### Mandatory else for call handlers
If a handler contains any `emit`, every code path must reach an emit:
- If an `if` block contains an emit, the `else` block is mandatory and must also emit
- A default emit after an if block satisfies this
- Nested if/else is checked recursively
- Cast handlers (no emit) are exempt

Produces `{:error, %{type: :incomplete_handler}}` on failure.

### Handler coverage for protocol accepts
Every `accepts` declaration in the protocol must have at least one handler with a matching message tag.

Produces `{:error, %{type: :missing_handler}}` on failure.

### Catch-all handler generation
For message tags with guarded handlers, the compiler generates catch-all clauses:
- Call messages: reply with `{:error, :no_matching_handler}`
- Cast messages: silently ignored (`keep_state_and_data`)

### Pattern matching depth
Vor handlers match one level deep: message tag + named fields. Nested destructuring is not supported. Bind the field and use map/list operations or extern calls for deeper access.

## Bidirectional relations

Relations support forward lookup, reverse lookup, and arithmetic inversion.

**Fact-based relations** can be queried from any field:
```vor
relation port_mapping(service: S, port: P) do
  fact(service: :http, port: 80)
  fact(service: :https, port: 443)
end
```

**Equation-based relations** are automatically inverted at compile time:
```vor
relation temp(celsius: C, fahrenheit: F) do
  F = C * 9 / 5 + 32
end
```
- Forward: provide C, get F
- Inverse: provide F, get C (compiler generates `C = (F - 32) * 5 / 9`)
- Limited to linear arithmetic (+, -, *, /)

## Resilience blocks

Declare what happens when a liveness invariant is violated:

```vor
resilience do
  on_invariant_violation("transaction terminates") ->
    transition phase: :terminated
end
```

Resilience handlers are generated as regular handler clauses and included in the state graph. The safety verifier checks them — recovery paths cannot introduce new safety violations.

## Guard asymmetry

Gen_statem handlers support full guard expressions: ==, in, >, <, >=, <=, and/or.
Gen_server handlers only support equality guards: `when field == :atom`.
For gen_server agents, use if/else in the handler body for comparisons.

## Invariant verification scope

Safety invariants tagged `proven` are verified by walking the state transition graph. The verifier currently supports:
- `never(phase == :state and emitted({:tag, _}))` — no emit of a message type in a given state
- `never(transition from: :a, to: :b)` — no direct transition between two states

The verifier fails closed:
- Unsupported invariant patterns produce a compile error when tagged `proven`
- Invariants that the verifier cannot verify are never silently accepted
- Extern-dependent conditionals on the verification path produce a compile error

Change to `monitored` for properties the verifier cannot yet check.

System-level invariants are verified by product state exploration (see Multi-Agent Model Checking).

## TLA+ specifications

The `tla/` directory contains TLA+ specs for the compiler's most critical modules:

- `VorSafetyVerifier.tla` — correctness of safety invariant verification
- `VorGraphExtraction.tla` — correctness of state graph extraction

If you modify `lib/vor/verification/safety.ex` or `lib/vor/graph.ex`, review the corresponding TLA+ spec. Run TLC to verify if you have the TLA+ tools installed.

These specs verify the algorithm, not the Elixir code directly. They define the contract; the Elixir code must satisfy it.

## Working examples

Five examples in the `examples/` directory:

- `lock.vor` — distributed lock with FIFO wait queue, proven safety ("no grant when held"), liveness timeout
- `circuit_breaker.vor` — three-state circuit breaker, proven safety ("no forward when open"), liveness recovery
- `gcounter.vor` + `gcounter_cluster.vor` — G-Counter CRDT with periodic gossip, zero externs
- `rate_limiter.vor` — parameterized rate limiter with ETS externs
- `raft.vor` + `raft_cluster.vor` — three-node Raft consensus with leader election, native majority check, system-level invariant "at most one leader" verifiable via `mix vor.check`

Additional CRDT types verified in tests (not separate example files):
- PN-Counter — two nested map_merge(:max) calls, zero externs
- Version-based OR-Set — entries + tombstones with map_merge(:max), zero externs

## Known limitations

1. No list/map iteration (map, filter, fold, for-each) — use extern calls for operations that need to traverse collections
2. No string operations native to the language — use extern calls
3. No explicit default values for data fields (`state x: integer = 5`) — uses implicit type defaults
4. No pattern matching on extern return values beyond simple comparison
5. No `match`/`case` expressions — only if/else
6. No nested pattern matching in handler patterns — match tag + top-level fields only
7. No guard coverage analysis (whether guards partition the input space) — catch-all handlers cover this at runtime
8. No nested builtin calls — `map_put(map_put(...), ...)` doesn't parse. Bind intermediate variables.
9. Multi-agent model checking is bounded — state space explosion for systems with many agents or unbounded integers. State abstraction (Phase 2) will help. Explorer reports honestly when bounds are exceeded.
10. System-level invariant syntax is limited to `count(agents where ...)` — `exists`, `for_all`, and named agent field references are Phase 3.

## Known design debt

### Atom interning

The lexer and lowering phases use `String.to_atom/1` on source-derived identifiers. On the BEAM, atoms are not garbage collected, so compiling large or untrusted source files can grow the atom table permanently. Acceptable for the current stage but must be addressed before the compiler runs in a long-lived service or accepts untrusted input.

Future fix: keep source names as binaries through lexer/parser/lowering, convert to atoms only at codegen.

### Warning visibility

Some analysis warnings are computed but not surfaced to the user during compilation. Dead accepts warnings are surfaced from `compile_system/1`. Other warnings in lowering and verification may be computed and dropped. Worth a sweep when moving toward production use.
