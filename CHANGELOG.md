# Changelog

## 2026-04-02
- **Fix: variable scoping in if blocks (GAP-009)** — Variables bound inside if branches are now visible to subsequent statements in the same branch. Protocol checker threads scope sequentially through actions.
- **Named agent registration (GAP-011)** — `start_link` accepts a `name` option for `{:local, atom}`, `{:global, term}`, or `{:via, module, term}` registration. Enables multiple instances of the same agent type. Backward compatible — agents without name start anonymously.
- **Fix: post-transition extern args (GAP-007)** — Extern call arguments now read post-transition state field values. Gen_server handler body rewritten to thread data variable sequentially through transitions and extern calls.
- **Fix: Erlang module extern calls (GAP-006)** — `Erlang.erlang.system_time(unit: :millisecond)` now correctly generates `erlang:system_time(...)` instead of `'Elixir.Erlang.erlang':system_time(...)`.
- **Fix: atom literals in map ops (GAP-008)** — Atom literals (`:value`, `:key`, `:not_found`) and `nil` now work in map_get key/default positions, map_put keys, map_has keys, map_delete keys.
- **Init handlers** — `on :init do ... end` runs once at startup before accepting messages. Supports extern calls, transitions, if/else, map/list ops. No emit/send/broadcast (compile error). Only one per agent. Extern failures caught — state fields keep defaults.
- **LWW map_merge strategy** — `map_merge(store, remote, :lww)` for Last-Writer-Wins CRDTs. Compares timestamps, tiebreaks by node_id. Idempotent.
- **Native list operations** — `list_head`, `list_tail`, `list_append`, `list_prepend`, `list_length`, `list_empty`. All handle empty lists safely. Lock example updated to use native ops — zero extern calls, fully native Vor.
- **Distributed lock example** — LockManager with exclusive access, FIFO wait queue, bounded hold time via liveness monitoring, and verified safety invariant (no grant when held). Queue operations via extern helpers. 50-client stress test passes.
- **Extern calls in if/else bodies** — Extern call bindings now work inside if/else branches (needed for lock's conditional queue operations).
- **Periodic timer (`every`) construct** — `every interval_ms do ... end` for scheduled periodic actions. Uses `erlang:send_after` (fires regardless of state changes, unlike liveness timeouts). Works in gen_server and gen_statem. Supports broadcast, send, transitions, extern calls. G-Counter updated to use `every` instead of liveness hack — now a clean gen_server.
- **G-Counter CRDT example** — Three-node grow-only counter with gossip-based sync using `map_merge(counts, R, :max)`. Fully native Vor — no extern calls. Periodic broadcast via liveness monitoring. Cluster convergence verified: concurrent increments across nodes converge to correct total.
- **Native map operations** — `map_get(m, k, default)`, `map_put(m, k, v)`, `map_has(m, k)`, `map_delete(m, k)`, `map_size(m)`, `map_sum(m)`, `map_merge(m1, m2, :max)`. Work in variable bindings, transitions, emit fields, for both gen_server and gen_statem.
- **Min/max expressions** — `min(a, b)` and `max(a, b)` as built-in expressions. Work in variable bindings, transitions, and emit fields. Useful for high/low water marks and CRDT merge strategies.
- **Tutorial with verified examples** — 8-step tutorial from Echo agent to multi-agent pipeline. Every code example compiles and runs. 11 tutorial tests verify all steps.
- **Compiler trace mode** — `Vor.Compiler.compile_string(source, trace: true)` prints stage-by-stage output: source stats, token count, AST structure, lowering target, verification results, codegen info, BEAM binary size. Also available via `mix vor.compile file.vor --trace`.
- **Property-based testing** — PropCheck generates random valid Vor programs and verifies compiler invariants: compilation safety, verifier soundness, graph extraction correctness, and protocol checking consistency. 9 properties, 100 iterations each.
- **Noop keyword** — `noop` in handler bodies for intentional no-ops. Valid in cast handlers; call handlers without emit still fail completeness check.
- **List literals** — `[]`, `[1, 2, 3]`, `[:a, :b]`, `[Var1, Var2]` in emit, send, broadcast, and transition fields. Raft example updated to use real lists instead of atom placeholders.
- **Conditional transitions in gen_statem** — Transitions inside if/else branches now take effect. Each branch produces its own gen_statem return with its own data map. Data map threaded through with unique variable names. Send and broadcast read post-transition values. Resilience handlers support broadcast and send.
- **Raft consensus example** — Three-node Raft cluster using native Vor primitives: `broadcast` for vote requests, `send` with variable targets for directed responses, liveness monitoring for election timeouts, proven safety invariants. All node-to-node messaging is native Vor — externs only used for log operations.
- **Variable send targets** — `send L {:msg, fields}` where L is a pattern-bound variable, resolved at runtime via Registry lookup. Enables directed responses in protocols like Raft.
- **Guard-safe data field comparison** — Guards like `when T > current_term` use `map_get/2` (guard BIF) instead of `maps:get/2`.
- **Init state timeouts** — Gen_statem agents that start in a monitored state now get the state_timeout set at init.
- **Resilience handler full actions** — Resilience handlers can now have multiple transitions, not just a target state.
- **Atom comparison in if conditions** — `if up_to_date == :true do` now parses correctly.
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
