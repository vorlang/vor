# Vor Compiler — Developer Guide

This document describes the current state of the Vor compiler. It is an internal reference for anyone working on the compiler, including AI coding agents. Update this document as features are added.

Last updated after: features 1-8 (externs, params, rate limiter, graph extraction, safety verification, circuit breaker, runtime monitoring, expressions & data map)

## Architecture

Pipeline: `.vor` source → Lexer → Parser → AST → IR (Lowering) → Analysis/Verification → Erlang codegen → BEAM binary

Key files:
- `lib/vor/lexer.ex` — NimbleParsec tokenizer
- `lib/vor/parser.ex` — Recursive descent parser
- `lib/vor/lowering.ex` — AST → IR transformation
- `lib/vor/codegen/erlang.ex` — IR → Erlang abstract format
- `lib/vor/compiler.ex` — Pipeline orchestrator
- `lib/vor/graph.ex` — State graph extraction
- `lib/vor/verification/safety.ex` — Safety invariant verification

## Agent compilation targets

- Agent with no `state` declaration → gen_server
- Agent with `state phase: :a | :b | :c` (enum union) → gen_statem
- First enum-typed state field → gen_statem State atom
- Additional state fields → entries in the gen_statem Data map with type defaults (integer→0, atom→nil)

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

## Known limitations

1. No list or collection operations native to the language — use extern calls
2. No string operations native to the language — use extern calls
3. No `solve` blocks for relation queries — use params directly
4. No explicit default values for data fields (`state x: integer = 5`) — uses implicit type defaults
5. No pattern matching on extern return values beyond simple comparison
6. No `match`/`case` expressions — only if/else
