# Vor Compiler — Developer Guide

This document describes the current state of the Vor compiler. It is an internal reference for anyone working on the compiler, including AI coding agents. Update this document as features are added.

Last updated after: Multi-agent model checking (Phases 1-3), state abstraction, symmetry reduction, quantified invariants, 349+ tests

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
- `lib/vor/explorer/product_state.ex` — Product state representation, abstraction, saturation
- `lib/vor/explorer/simulator.ex` — IR handler action interpreter
- `lib/vor/explorer/successor.ex` — Successor state computation
- `lib/vor/explorer/invariant.ex` — System-level invariant evaluation (count, exists, for_all, named refs)
- `lib/vor/explorer/relevance.ex` — Field relevance analysis for state abstraction
- `lib/vor/explorer/symmetry.ex` — Symmetry detection and canonical fingerprinting
- `lib/mix/tasks/vor.check.ex` — Mix task for multi-agent model checking

## Agent compilation targets

- Agent with no `state` declaration → gen_server
- Agent with non-enum state fields only (`state count: integer`) → gen_server with state map
- Agent with `state phase: :a | :b | :c` (enum union) → gen_statem
- First enum-typed state field → gen_statem State atom
- Additional state fields → entries in the Data/State map with type defaults (integer→0, atom→nil, map→%{}, list→[], binary→<<>>)
- Parameters and state fields share the same map for both gen_server and gen_statem

## Named agent registration

Agents accept an optional `name` in the args keyword list. If present, passed to `GenServer.start_link/3` or `:gen_statem.start_link/4`. If absent, starts anonymously. System blocks handle naming automatically via the Registry.

## Init handlers

`on :init do ... end` runs once during agent startup, before accepting messages. Supports extern calls, variable bindings, transitions, if/else, map/list operations, parameter references. Does NOT support emit, send, broadcast (compile error). Only one per agent. Extern failures caught — state fields keep defaults. Runs after parameter extraction, before `every` timers start.

## What works in handler bodies

### Expressions
- Arithmetic: +, -, *, / with any operand order (var OP var, var OP int, int OP var)
- Variable binding from extern calls, arithmetic, pattern matching
- Parameter and data field references in emits and extern args
- Min/max: `min(a, b)`, `max(a, b)`
- Atom literals in all expression positions
- Noop: explicit no-operation statement

### Map operations
- `map_get(map, key, default)`, `map_put(map, key, value)`, `map_has(map, key)`, `map_delete(map, key)`, `map_size(map)`, `map_sum(map)`, `map_merge(map1, map2, strategy)`
- Merge strategies: `:max`, `:min`, `:sum`, `:replace`, `:lww`
- All operations work on state fields AND local variables

### List operations
- `list_head(list)`, `list_tail(list)`, `list_append(list, value)`, `list_prepend(list, value)`, `list_length(list)`, `list_empty(list)`
- All handle empty lists safely

### Conditionals
- If/else with operators: `<=`, `>=`, `==`, `!=`, `>`, `<` and boolean `and`/`or`
- Nested if/else, full statement set inside bodies
- Variables scoped to their branch, all extern types work inside if blocks

### Guards
- Gen_statem: `==`, `in`, `>`, `<`, `>=`, `<=`, `and`/`or`
- Gen_server: equality guards only (`when field == :atom`)

### State management
- Enum state fields → gen_statem State atom
- Data fields → Data map with type defaults
- Multiple transitions collapsed into single state change
- Sequential compilation: each statement sees results of all previous statements

### Periodic timers
- `every interval_ms do ... end` — periodic execution with send_after
- Interval from literal or parameter; timers start after `on :init` completes

## Internal type tracking

The compiler propagates types through handler body expressions:
- **Error** (blocks compilation): guaranteed crashes — `store + 1` where store is map
- **Warning** (compiles): likely problems — assigning map to integer field
- **No diagnostic**: operations on `term`
- Type sources: state declarations, parameters, built-in operation results, Gleam extern return types
- Message pattern variables always `term`; `:: term` opts out of type tracking

## What works in invariants

### Safety (proven, single-agent)
- `never(phase == :state and emitted({:msg, _}))` — verified by graph walk
- `never(transition from: :a, to: :b)` — verified by graph walk
- Resilience handlers included in graph and verified
- Proven invariants cannot depend on extern results

### Liveness (monitored)
- `always(phase != :idle implies eventually(phase == :done))` — runtime via gen_statem state timeouts
- Requires matching resilience handler; timeout from agent parameters

### System-level safety (proven, multi-agent via `mix vor.check`)
- `never(count(agents where FIELD OP VALUE) COMP N)`
- `never(exists A, B where CONDITION)` — two distinct agents
- `never(exists A where CONDITION)` — single agent
- `for_all agents, CONDITION` — universal
- Named agent references: `n1.role == :leader`
- Cross-agent comparisons: `A.current_term != B.current_term`
- Boolean composition with `and`/`or` in conditions

## Extern declarations

### Three types
- **Elixir:** `extern do MyModule.func(arg: type) :: type end` → `'Elixir.MyModule':func(Arg)`
- **Erlang:** `extern do Erlang.mod.func(arg: type) :: type end` → `mod:func(Arg)`
- **Gleam:** `extern gleam do mod/sub.func(arg: type) :: type end` → `'mod@sub':func(Arg)`

### Keyword parameter names
Vor keywords accepted as parameter names in extern declarations.

### Extern trust boundary
- All extern calls wrapped in try/catch
- Proven invariants cannot depend on extern results (path-precise taint tracking, compile error)
- Resolution: remove extern dependency, change to `monitored`, or restructure handler

### Gleam type boundary validation
- Reads `package-interface.json` when available
- Validates arity, parameter types, return types
- Type mapping: Int→integer, String→binary, Bool→atom, List→list, Dict→map, custom→term
- `:: term` opts out; validation optional (no JSON = no check)

## Multi-agent model checking

### Execution
```bash
mix compile              # parses system invariants, does NOT explore
mix vor.check            # BFS exploration of product state space
mix vor.check --depth 30 --max-states 200000 --integer-bound 5 --max-queue 15
mix vor.check --no-symmetry
```

### How it works
1. Compute relevant fields (transitive closure from invariant through guards/conditionals)
2. Abstract irrelevant fields to `:abstracted` (treated as `:unknown` during simulation)
3. Saturate tracked integers at configured bound
4. Construct initial product state (all agents in initial states)
5. BFS explore successors: pending message delivery + protocol-driven external events + timeouts
6. Dedup via fingerprint (abstracted, sorted messages; canonical under symmetry)
7. Check all system invariants at each reachable state
8. Report: proven / bounded / violation with counterexample trace

### State abstraction
- Relevance analysis: invariant fields → guard-influencing fields → transitive closure
- Parameters identified as constants (excluded from state dimensions)
- Abstracted fields read as `:unknown` during simulation (conservative, both branches explored)

### Integer saturation
- Tracked integer fields capped at configurable bound (default 3)
- Prevents unbounded state space from numeric fields
- Standard bounded model checking technique

### Queue bounding
- Pending message queue capped at configurable bound (default 10)
- Messages beyond the cap are dropped (models bounded network buffer)

### Symmetry reduction
- Auto-detected for homogeneous fully-connected systems
- Canonical fingerprint sorts agent states, strips sender/receiver identity from messages
- Disabled for heterogeneous systems or invariants with named agent references
- Raft: 1,001 states with symmetry vs 8,008 without (8× reduction)

### Simulator
- Interprets IR.Handler.actions directly (no separate transition table)
- `:unknown` propagated through arithmetic, comparisons, value refs
- Conditionals on `:unknown` fan out into both branches
- `:abstracted` fields treated same as `:unknown`
- State-change-only exploration: skip no-op successors

### Counterexample traces
Show each step: action taken, resulting agent states, pending messages. Developer can walk the trace to understand the exact message interleaving that caused the violation.

## Multi-agent systems

### Protocol declarations
- `accepts` — incoming messages; `emits` — synchronous replies; `sends` — async forwards via Registry

### System blocks, protocol composition, send codegen, broadcast
Same as before. Broadcast to all outbound connections, async, graceful missing-peer handling.

## Handler completeness, catch-all generation, pattern matching depth
Mandatory else for call handlers with emit. Handler coverage for all `accepts`. Catch-all generation for guarded handlers. One-level-deep pattern matching only.

## Bidirectional relations
Fact-based (multi-directional lookup) and equation-based (automatic inversion, linear arithmetic only).

## Resilience blocks
Declare recovery for liveness violations. Generated as regular handler clauses, included in state graph, verified by safety checker.

## TLA+ specifications
`VorSafetyVerifier.tla` and `VorGraphExtraction.tla` in `tla/` directory. Review when modifying the corresponding Elixir modules.

## Working examples

- `lock.vor` — distributed lock, proven safety, liveness timeout
- `circuit_breaker.vor` — three-state, proven safety, liveness recovery
- `gcounter.vor` + `gcounter_cluster.vor` — G-Counter CRDT, zero externs
- `rate_limiter.vor` — parameterized, ETS externs
- `raft.vor` + `raft_cluster.vor` — three-node Raft, native majority check, "at most one leader" proven in 1,001 states via `mix vor.check`
- Test-only CRDTs: PN-Counter, version-based OR-Set (zero externs)

## Known limitations

1. No list/map iteration — use extern calls
2. No string operations — use extern calls
3. No explicit default values for data fields
4. No pattern matching on extern return values beyond comparison
5. No `match`/`case` expressions — only if/else
6. No nested pattern matching in handler patterns
7. No guard coverage analysis
8. No nested builtin calls — bind intermediate variables
9. Multi-agent model checking is bounded — state abstraction and symmetry help but large systems may exceed bounds
10. System-level liveness not yet supported — safety only in the product graph (Phase 4)

## Known design debt

### Atom interning
`String.to_atom/1` on source identifiers. Must address before long-lived service or untrusted input.

### Warning visibility
Some analysis warnings computed but not surfaced. Worth a sweep for production use.
