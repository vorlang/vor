# Changelog

## 2026-04-02
- **Broadcast** — `broadcast {:msg, fields}` sends a message to all outbound-connected agents in the system block. Always asynchronous (cast). Works alongside `emit` and `send` in the same handler. Checks against `sends` protocol declarations. Generated code iterates `__vor_connections__` and sends via the registry with graceful handling of missing peers.
- **Soundness fix: proven invariant fail-closed** — Unsupported `proven` invariant bodies now produce compile errors instead of silently passing. The safety verifier also accepts any state field name, not just `phase`.
- **Soundness fix: graph extraction uses declared state field** — State graph only extracts transitions for the declared enum state field, preventing non-state guards from corrupting the graph.
- **System runtime fix: metadata propagation** — Agent init now extracts `__vor_registry__` and `__vor_name__` from system args, enabling `send` between agents at runtime. Tested end-to-end with two-agent send and three-agent pipeline.
- **Gen_server cast handlers** — Gen_server handlers now generate both `handle_call` and `handle_cast` clauses, so `send` (which uses `gen_server:cast`) reaches the correct handler.
- **Zero compiler warnings** — Removed dead code (`compile_conditional/3`, `gen_params_map/2`), fixed unused variables, removed unreachable clauses.

## 2026-04-01
- **Handler completeness checking** — Call handlers (those with emit) must emit on every code path. Missing else branches on if/emit blocks produce compile errors. Recursive analysis handles nested if/else. Cast handlers without else remain valid.
- **Handler coverage enforcement** — Every `accepts` in the protocol must have at least one handler. Missing handlers produce compile errors with suggestions.
- **Catch-all handler generation** — Guarded handlers automatically get catch-all clauses. Calls return `{:error, :no_matching_handler}` instead of crashing. Casts are silently ignored.
- **Bidirectional relation solver** — Relations are queryable from any direction. Equation-based relations (`fahrenheit = celsius * 9 / 5 + 32`) support compile-time symbolic inversion. Forward and inverse solve in handlers via `solve` blocks.
- **Gen_server data state** — Gen_server agents can declare mutable state fields (`state count: integer`). Fields stored in the GenServer state map with type defaults. Transition, read, and update in handlers.
- **Protocol composition checking** — `system` blocks wire agents together with `connect`. The compiler verifies that connected agents' `sends` and `accepts` have matching tags and field names. Mismatches fail compilation.
- **Multi-agent systems** — `sends` protocol declaration, `send :target {:msg, fields}` in handlers, `system` blocks with `agent` instances and `connect` topology.
- **Multiple state fields** — First enum field becomes gen_statem State, others go in Data map with type defaults.
- **Gen_statem call support** — Handlers now respond to both `cast` and `call` events. Call replies include the emitted value.
- **Richer expressions** — Standalone variable binding (`x = a + 1`), nested if/else, boolean `and`/`or` in conditions, comparison operators in guards (`>`, `<`, `>=`, `<=`), int-first arithmetic (`10 - V`).
- **Transition with expressions** — `transition count: count + 1`, `transition voted_for: C`. Data field transitions generate map updates.
- **Runtime liveness monitoring** — `monitored(within: duration)` liveness invariants generate gen_statem state timeouts that rescue stuck processes via resilience handlers.
- **Compile-time safety verification** — `proven` safety invariants are verified against the state transition graph at compile time. Violations fail compilation.
- **State graph extraction** — `mix vor.graph` prints text or Mermaid diagrams of gen_statem state machines.
- **Circuit breaker example** — Verified state machine with safety invariants: open state cannot forward requests.
- **Working rate limiter example** — Flagship example combining params, externs, conditionals, arithmetic, and invariants with ETS-backed storage.
- **If/else conditionals** — Handler bodies support `if expr do ... else ... end` with comparison operators.
- **Arithmetic expressions** — Emit fields support arithmetic (`remaining: max_requests - current`).

## 2026-03-30
- **Parameterized agents** — Agents accept configuration parameters at init, available as immutable values in handlers.
- **Extern declarations** — Vor agents can call Erlang/Elixir functions via `extern do` blocks with try/catch safety wrappers.

## 2026-03-29
- **Initial compiler** — Full pipeline from `.vor` source to BEAM binary, supporting agents, relations, state, protocols, handlers, guards, invariants, and resilience declarations.
