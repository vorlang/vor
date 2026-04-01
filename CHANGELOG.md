# Changelog

## 2026-04-01
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
