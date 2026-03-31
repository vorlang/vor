# Changelog

## 2026-03-30
- **Parameterized agents** — Agents accept configuration parameters at init, available as immutable values in handlers.
- **Extern declarations** — Vor agents can call Erlang/Elixir functions via `extern do` blocks with try/catch safety wrappers.

## 2026-03-29
- **Initial compiler** — Full pipeline from `.vor` source to BEAM binary, supporting agents, relations, state, protocols, handlers, guards, invariants, and resilience declarations.
