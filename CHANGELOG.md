# Changelog

## 2026-04-01
- **Multiple state fields** — First enum field becomes gen_statem State, others go in Data map with type defaults. Raft-like agents with `role`, `current_term`, `vote_count` work.
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
