# Codegen Conformance — killing the silent-drop class

The recurring failure class: somewhere in lowering/codegen, action dispatch
*filters* instead of *exhaustively handling* — a `case`/comprehension quietly
skips an action it doesn't recognize in a given context, instead of refusing to
compile. Found three times by accident (timer gap, routing bug, `:*_fired`
drop). This suite makes the class structurally impossible (Part A) and proves the
surviving combinations work at runtime by **observable effect** (Part B).

Baseline: `main` @ (pre-fix). Handler-body IR action set (from `Vor.IR` +
`Vor.Lowering.lower_action/2`): `transition` (enum state change *and* data-field
update), `emit`, `send`, `broadcast`, `var_binding`, `conditional`,
`extern_call`, `solve`, `start_timer` / `cancel_timer` / `restart_timer`,
`function_call`, `noop`.

---

## A.1 — Dispatch-point enumeration (before any change)

Every place codegen/lowering dispatches an action by type within a handler
context, and what happens to an action the branch doesn't recognize:

| # | Location | Context(s) it serves | Unhandled action → | Verdict |
|---|---|---|---|---|
| DP0 | `split_terminal/1` (`erlang.ex:372`) — `Enum.take(actions, idx)` | gen_server message handler | **actions *after* the first emit/conditional/solve are silently discarded** | **SILENT DROP (new finding)** |
| DP1 | gen_server pre-action loops (`erlang.ex:239,282,323`) — `case action … _ -> action_to_erl(...)` | gen_server message handler | routes to DP5 | inherits DP5 |
| DP2 | gen_server terminal dispatch (`erlang.ex:336`) — `case terminal … nil ->` (no `_`) | gen_server terminal | constrained to emit/conditional/solve/nil by `split_terminal`; cannot fall through | safe |
| DP3 | `compile_statem_actions_v2/7` catch-all (`erlang.ex:996`) — `_ -> {exprs, dv, c, false}` | gen_statem message / state_timeout / periodic handlers | **silently skipped** | **SILENT SKIP** |
| DP4 | `compile_statem_body/4` catch-all (`erlang.ex:1055`) — `_ -> {exprs, state, updates, emit}` | `:*_fired`, gen_statem conditional branches | **silently skipped** (also `:solve` unhandled) | **SILENT SKIP** |
| DP5 | `action_to_erl/3` catch-all (`erlang.ex:1799`) — `_ -> []` | anything routed here: gen_server pre-actions, init, statem send/bcast/extern | **silently dropped** (handles only extern_call, var_binding, send, broadcast; misses transition, emit, conditional, solve, timers, function_call) | **SILENT DROP** |
| DP6 | `gen_timer_info_clauses/2` (`erlang.ex:1121`) — builds clause body as only `[{:next_state, state, Data}]`, discarding `body_exprs` | `:*_fired` message-timer handler | **all non-transition actions dropped** (send/broadcast/data-update/emit) | **SILENT DROP (known)** |
| DP7 | `compile_init_handler_body/3` (`erlang.ex:756`) — transitions handled, others via `action_to_erl` | `on :init` | routes to DP5 | inherits DP5 |
| DP-L1 | `lower_action/2` (`lowering.ex:279–496`) — no catch-all clause | all (AST→IR) | `FunctionClauseError` (loud crash, not silent) | crash, not drop |

**Confirmed empirically (pre-fix):**
- **DP0** — `on {:go} do emit {:done}; transition count: count+1 end` (gen_server): reply is `{:done, %{}}`, but `:sys.get_state` shows `count: 0` — the post-emit transition is **dropped**.
- **DP6** — `on :wake_fired do transition …; broadcast {…} end`: the broadcast never reaches peers (see B.4).
- **emit-in-timer** — `emit` in `every`/timeout/`:*_fired` produces no message (no caller to reply to); dropped as dead code.

The catch-alls at DP3, DP4, DP5 and the body-discard at DP6, plus the
take-until-terminal at DP0, are the concrete instances of the class. A.2 turns
each into an explicit compile error; A.3 decides fix-vs-reject for the reachable
cells.

---

## B.1 — The matrix

Actions (observable-effect axis) × handler contexts. Observation method per
action: `transition_enum`/`data_update` via `:sys.get_state`; `emit` via the
caller's reply tuple; `send`/`broadcast` via a **real peer's** state in a
two-agent system (never the sender's telemetry). Generated + run by
`test/features/codegen_conformance_test.exs`.

| action ↓ / context → | message | guarded | every | :\*_fired | resilience | init |
|---|---|---|---|---|---|---|
| transition (enum) | ✅ | ✅ | ✅ | ✅ | ✅ | n/a¹ |
| data update | ✅ | ✅ | ✅ | ❌ **drop** | ✅ | ✅ |
| emit (reply) | ✅ | ✅ | ⛔ reject² | ⛔ reject² | ⛔ reject² | ⛔ reject² (already) |
| send | ✅ | ✅ | ✅ | ❌ **drop** | ✅ | ✅ |
| broadcast | ✅ | ✅ | ✅ | ❌ **drop** | ✅ | ✅ |

¹ `transition_enum` in `init` runs before the initial state is entered — it
crashed at startup pre-fix (`KeyError :phase`); classified reject/na (the suite
asserts it does not come up reporting the transition as applied).
² caller-less contexts have no one to reply to; `emit` there is dead code and
must be an explicit compile error. `init` already rejects it
(`:invalid_init_handler`); the others silently dropped it (pre-fix).

Also tested: **DP0** — a gen_server handler with a `transition` *after* `emit`.

## B.4 — Recorded RED run (pre-fix codegen)

`mix test test/features/codegen_conformance_test.exs` → **32 tests, 7 failures**.
The 25 green cells confirm the working contexts. The 7 red:

| # | cell | effect | dispatch |
|---|---|---|---|
| 1 | gen_server: data update after `emit` | dropped (hits=0) | **DP0 (new finding)** |
| 2 | `:*_fired` / data update | dropped (hits=0) | DP6 |
| 3 | `:*_fired` / send | peer never received | DP6 |
| 4 | `:*_fired` / broadcast | peer never received | DP6 |
| 5 | `every` / emit | compiled silently (should reject) | DP3/DP5 |
| 6 | `:*_fired` / emit | compiled silently (should reject) | DP4/DP6 |
| 7 | `resilience` / emit | compiled silently (should reject) | DP3 |

`:*_fired` / transition (enum) is **green** — `gen_timer_info_clauses` keeps the
enum state change (the one thing it applies) and drops everything else, exactly
as the code predicts. No red cells beyond the two known classes and the
predicted DP0 — the prior expectation (each instance found by accident implies
more) held: DP0 is the new one.

## A.3 — Fix / reject decisions

- **DP6 (`:*_fired` non-transition actions) → FIX.** Real functionality: a
  message-timer handler that sends/broadcasts or updates data is clearly
  meaningful. Route `:*_fired` through the same handler-body compiler the
  periodic/resilience contexts already use, instead of the lossy path that kept
  only the enum transition.
- **DP0 (gen_server actions after the terminal) → FIX.** `emit {…}; send {…}`
  (reply, then notify) is meaningful; preserve post-terminal side-effect actions
  rather than dropping them.
- **emit in caller-less contexts (every / `:*_fired` / resilience) → REJECT.**
  No caller to reply to; make it the same explicit compile error `init` already
  gives.
- **The silent catch-alls (DP3/DP4/DP5) → REJECT (structural, A.2).** Any
  action×context a dispatch point does not explicitly handle raises a compile
  error naming the action, the context, and the source location — never a silent
  skip/empty-list.

## Implemented (Part A) + GREEN run

- **DP6 fixed** — `gen_timer_info_clauses` now compiles `:*_fired` bodies through
  the full `compile_statem_handler_body` (nil call_info), the same path
  periodic/resilience use, so transitions, data updates, sends, and broadcasts
  all fire. The lossy legacy `compile_statem_body` cluster (which had kept only
  the enum state change — **DP4**) is deleted, removing that dispatch point
  entirely.
- **DP0 fixed** — `split_terminal/1` now returns `{before, terminal, after}` and
  `compile_handler_body` threads the *after* actions (post-emit
  send/broadcast/transition) instead of dropping them; the reply carries the
  final state.
- **emit-in-caller-less rejected** — `Vor.Compiler.validate_caller_less_emit/1`
  (a validation pass, sibling to the init check) returns
  `{:error, :caller_less_emit, …}` for `emit` in a periodic `every` timer,
  a `:*_fired` handler, or a resilience handler.
- **Structural exhaustiveness (A.2)** — `action_to_erl/3` and the gen_statem
  body reducer no longer fall through to a silent `[]`/skip: `noop` (nil) is an
  explicit no-op, and any unhandled action type **raises** a "codegen gap … would
  be silently dropped" error naming the action type.
- **Additional finding, fixed** — surfaced by the matrix while wiring A.2: a
  gen_server handler of the shape `if <side-effects> end; emit {…}` had the `if`
  mis-classified as the reply-terminal, so the trailing `emit` was dropped and
  the handler silently replied `:ok` instead of the declared message. Fixed by
  threading post-`if` actions into **both** branches (mirroring the gen_statem
  path); verified `{:process, value: 5}` → `{:done, %{count: 5}}` at runtime.
  This is the fourth instance of the class, and — as the brief predicted — it was
  found while fixing the others.

**GREEN run:** `mix test test/features/codegen_conformance_test.exs` → **32/0**.
Full suite **528 tests, 0 failures**, zero warnings. The conformance suite runs
in the normal `mix test` flow, and its `test "matrix covers the handler-relevant
IR action set"` trips if a new observable IR action type is added without a
matrix row.
