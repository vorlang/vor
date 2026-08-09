# Known Issues

This document records confirmed defects in Vor's verification tooling as of
**July 2026**. The intent is an accurate account a user can rely on, not a
roadmap.

Summary of impact: **single-agent verification, protocol constraints,
backpressure, generated telemetry, and chaos simulation work as described.
Multi-agent bounded model checking does not verify any behavior that is gated
behind a timer, timeout, or resilience handler.** Any multi-agent
model-checking result for such behavior is vacuous. (The formerly-unsound
symmetry reduction has since been removed — see §2.)

---

## 1. Timer / resilience transitions — FIXED (July 2026, Phase 3a)

**History.** The explorer's successor relation originally generated successors
from only two sources — delivering a pending message, and injecting one
representative `accepts` message per type — and never fired `monitored`
timeouts, `resilience` handlers, periodic `every` timers, or bare timer-atom
handlers. Any transition reachable only through such a trigger was dead code, so
invariants about it were **vacuously true**: the checker returned `Proven ✓` over
a state space from which the interesting states were absent. This is what let
Raft report "at most one leader, proven in 1,001 states" over a space in which
every node was a follower (see
[`evidence/phase1-vacuity-report.md`](evidence/phase1-vacuity-report.md)).

**Fix.** `Vor.Explorer.Successor` now fires timers as nondeterministic,
always-enabled successors (the standard model-checking treatment). Election,
circuit-breaker recovery, and G-Counter gossip are now reachable. What that
revealed, per [`evidence/phase3a-timer-measurement.md`](evidence/phase3a-timer-measurement.md):

| Example | After the fix |
|---|---|
| **Raft** (`examples/raft_cluster.vor`, `examples/raft.vor`) | Election fires; `:candidate`/`:leader` reachable. The originally-shipped *global* `never(count(role == :leader) > 1)` was thereby exposed as **mis-specified** (violated by a legal transient stale leader in a different term — Raft guarantees one leader *per term*). It has been **corrected** to per-term uniqueness (`never(exists A, B where both leader and same term)`), which is now **PROVEN and substantive** — Vor's first genuinely non-vacuous multi-agent result (see [`evidence/phase3a-timer-measurement.md`](evidence/phase3a-timer-measurement.md) §7). |
| **Circuit breaker** (`examples/circuit_breaker.vor`) | `:half_open` now reachable; the recovery/probe subtree is exercised. |
| **G-Counter** (`examples/gcounter.vor`, `examples/gcounter_cluster.vor`) | Gossip `every` timer fires. **But** map ops still abstract to `:unknown`, so convergence *content* is reachable-but-not-checkable — see issue #5. |
| **Lock**, **Rate limiter** | Unchanged (controls). |

`--no-fire-timers` restores the old blind mode (useful for isolating other
mechanics; it is the mode in which results are vacuous).

**Remaining limitation — tractability (see #4).** Firing timers makes the state
space explode: exhaustive exploration is tractable only at small bounds (queue
≤ 3), and the old reference config (queue 10) no longer terminates. Bug-finding
(shallow counterexamples) stays cheap. Multi-agent model checking is an opt-in
deep check / bug-finder, not a compile-time operation.

---

## 2. Symmetry reduction — RESOLVED BY REMOVAL (2026-08-08)

Symmetry reduction was **deleted**, not repaired. The former
`Vor.Explorer.Symmetry.canonical_fingerprint/1` was not orbit-exact: it performed
three uncoordinated collapses (sorted the per-agent states into a multiset,
stripped from/to endpoints from pending messages and bagged the payloads, and
kept payload agent IDs verbatim) with no single permutation tying them together,
so it could map states in **different Sₙ orbits** to the same fingerprint and
prune reachable states — and any counterexample reachable only through them
(**unsound**, not merely imprecise; the arithmetically-impossible 8× on the
vacuous Raft fixture, where a correct S₃ quotient caps at 6×, was the tell). It
was already opt-in with unsound-warnings, and the honest-model measurement showed
a *correct* fix would buy only ~2× — so unsound + marginal made repair not worth
the ongoing cost of preserving its code paths, warnings, and tests through every
explorer change. The full analysis and the constructed cross-orbit counterexample
live in `evidence/phase3a-timer-measurement.md`,
`evidence/por-and-voting-diagnostics.md`, and the tombstone
`test/features/symmetry_soundness_test.exs`. Removal is behaviorally invisible:
symmetry was already off by default, and the sound default-path state counts are
unchanged (verified against the `evidence/phase3c-por-measurement.md` §7
baseline).

---

## 3. Identifier routing — FIXED (July 2026)

A system-block param such as `node_id: :node1` was stored in agent state as the
unlowered AST literal `{:atom, "node1"}` rather than the bare atom `:node1`, while
agents are keyed by the bare atom. A directed reply `send C {...}` whose target
`C` came from a message payload carrying a `node_id` was therefore addressed to
`{:atom, "node1"}`; `Successor.dispatch` could not match it against the agent
keys and **silently dropped the reply**.

This was latent in the original Raft (`send C {:vote_granted, ...}`), surfacing
only once candidates become reachable — with directed replies dropped,
`vote_count` could never reach a majority and no leader could ever be elected,
independent of issue #1.

**Fix:** atom-literal param values are now lowered to bare atoms at IR
construction (`Vor.Compiler.lower_system_block` / `normalize_param_value`), with
defensive normalization at the two resolution boundaries
(`Vor.Explorer.Simulator.resolve_target` and `Vor.Explorer.Successor.dispatch`).

**Verification:** `test/features/directed_send_routing_test.exs` (a directed send
addressed to a payload-carried `node_id` is now delivered). The fix **did not
change any existing example's state count** — the routing bug was fully masked by
issue #1 (no directed reply was ever attempted in the shipped, candidate-free
examples). It is exercised only once elections are made reachable, where it now
correctly allows `vote_count` to reach a majority and a leader to be elected.

---

## 4. Multi-agent checking is a bug-finder, exhaustive only at small bounds

With timers firing (issue #1 fixed) the honest Raft state space explodes with the
message-queue bound (~8–15× per slot). Partial-order reduction (Phase 3c) was
expected to attack this, and an initial (unsound) version measured ~20×; once made
sound (see #6) it buys **~1× on this model** and does not move the frontier —
Raft's election-timeout timer *broadcasts* and is enabled almost everywhere, so a
queue-growing event nearly always blocks reduction. So exhaustive checking is
tractable only at small bounds (queue ≤ 3), and the interleaving-explosion wall
stands. The checker is a **fast bug-finder** (counterexamples surface in well
under a second, even at wide bounds, because BFS reaches a shallow violation
before the space blows up) that can **also** do **bounded exhaustive verification
at small configs**. It is **not** compile-time verification of distributed
systems, and `mix compile` never runs it. The old **1,001-state figure was small
because the model was empty** (all followers). Full measurements:
[`evidence/phase3a-timer-measurement.md`](evidence/phase3a-timer-measurement.md)
and [`evidence/phase3c-por-measurement.md`](evidence/phase3c-por-measurement.md)
(the latter's §7 has the corrected, sound numbers).

The interface reflects this: `mix vor.check` defaults to a fast smoke check at
small bounds, `--deep` opts into wider bounds for bounded verification, and a `✓`
is reported as "no counterexample within bounds", never as an unconditional proof.

---

## 5. Map operations abstract to `:unknown` (convergence not checkable)

`Vor.Explorer.Simulator` evaluates map operations (`map_put`, `map_merge`,
`map_get`, `map_sum`) to the symbolic value `:unknown`. For the G-Counter
examples this means that, even now that gossip fires (issue #1), the CRDT's
`counts` map never takes a concrete value — so a "replicas converge" invariant
is *reachable* but not *checkable*. This is a distinct limitation from the timer
gap. Protocols whose safety depends on map/collection contents cannot currently
be verified at the value level; enum-state and integer properties are unaffected.

---

## 6. Partial-order reduction — cap_queue independence — FIXED (July 2026)

POR's soundness rests on "two events aimed at different agents commute". That is
true under the faithful message multiset, but **not** under the lossy bounded
queue: `cap_queue` keeps the *first* `max_queue` messages and drops the tail, so
two orders that saturate the queue can drop different messages and fail to
commute. The original Phase 3c POR ignored this and reduced across such states —
verdict-preserving on the examples, but unsound in principle, and the source of
the inflated ~20× figure.

**Fix.** `Vor.Explorer.POR.ample/5` now gates reduction on queue-safety: it
reduces only when no enabled event grows or truncates the queue (a queue-growing
or truncating event is treated as dependent). This is the obviously-sound choice
over the minimal-reduction-loss one; the rejected alternative — making the drop
order-independent — would change the model (which messages the lossy network
drops), shifting non-POR results too. Regression: `test/features/por_test.exs`
builds the non-commuting saturated state and asserts POR keeps the full set
(red→green against the pre-fix code). Consequence: sound POR now buys ~1× on the
honest Raft model (see #4 and `evidence/phase3c-por-measurement.md` §7).

---

## 7. Codegen silent-drop class — RESOLVED (2026-08-08)

Three times, generated code silently did less than the source declared: the
timer gap (#1), the routing bug (#3), and the `:*_fired` action drop
(message-timer handlers kept only the enum transition and discarded
`send`/`broadcast`/data updates), plus its sibling — `emit` in a caller-less
context, dropped as dead code. One failure class: a codegen dispatch point that
*filtered* instead of *exhaustively handling*, quietly skipping actions it didn't
recognize in a given context.

**Resolved.** Every dispatch point now either handles an action or refuses to
compile — nothing falls through silently: `:*_fired` handlers run their full body
(fix); `emit` in a periodic/`:*_fired`/resilience handler is an explicit compile
error (`:caller_less_emit`, reject); gen_server actions *after* the reply
terminal are threaded through instead of dropped (a fourth instance, DP0, found
while fixing the others — including `if <side-effects> end; emit {…}` which used
to reply `:ok`); and the shared per-action compiler raises a "codegen gap … would
be silently dropped" error on any unhandled action type. Proven by a generated
**conformance matrix** (`test/features/codegen_conformance_test.exs`, in the
normal `mix test`) that asserts each action's *observable effect* — a real peer
receives the message, `:sys.get_state` shows the value, the caller gets the reply
— never telemetry alone. Full enumeration, the pre-fix red run, and the fix/reject
decisions: `evidence/conformance-matrix.md`.

---

## 8. Value invariants — fail-closed + explorer init (RESOLVED / partial, 2026-08-08)

Surfaced by the first data-carrying use-case (`usecases/01-inventory.md`):

**F3 — a `proven` value invariant that was silently vacuous (RESOLVED).** A
gen_server has no state-machine graph, so `verify_safety` had nothing to check and
returned `:ok` — a `proven` value invariant (`never(available < 0)`,
`never(reserved + available != total)`) passed by omission. A mutation
(unconditional `available - Q`, which trivially reaches negative stock) still
compiled as proven. The gen_statem path already refused such a body; the
gen_server path fake-proved it. Fixed: `verify_safety` now fails closed — an
unverifiable `proven` safety invariant (no-graph, or an `{:unknown}` body) is
refused with a **teaching** `:unsupported_invariant` message that routes the
author to `mix vor.check` (system tier) or `monitored`. The principle, verbatim:
*never claim to have verified a property you never exercised.* Regression:
`test/features/value_verification_test.exs` (the mutation must not compile as
proven). No shipped example relied on the silent skip.

**F4 — the explorer ignored `on :init` (RESOLVED).** Integer state defaulted to 0
and `mix vor.check` did not run `on :init`, so a data-carrying agent started at
the origin (guarded handlers dead, invariants vacuous). Fixed: the explorer
applies the init handler to its initial `ProductState`, guarded by a
model-vs-reality test (checker initial state == runtime `:sys.get_state`).

**Still open.** F1 — value inequalities/arithmetic (`available >= 0`,
`reserved + available == total`) are inexpressible as *system* invariants (the
grammar is `==`/`!=` per-agent). F8 — the explorer does not drive a *driverless*
agent (no incoming connection/client), so a standalone data-carrying agent is not
exercised past init. Both logged in `usecases/01-inventory.md`; neither fixed here.

---

## 9. Liveness tier — checking, coverage, failure channel (RESOLVED 2026-08-09; F14 open)

Surfaced by the first liveness-dominant use-case (`usecases/02-jobqueue.md`,
Probe 2). The runtime mechanism works — a monitored deadline fires and its
resilience handler recovers on real BEAM processes — but every tier that was
supposed to *check* or *report* it was vacuous or blind. All four defects fixed
in the 2026-08-09 fix round (see CHANGELOG); F14 (per-job properties) stays open
as a language-design question.

**F10 — system-tier `liveness … proven` returned `proven` for stuck systems
(RESOLVED).** The detection machinery (`run_liveness_check`) *did* find the
violations — a terminal deadlock sink via `check_terminal_liveness`, a
non-progress cycle via the SCC check — and wrote them into
`stats.liveness.results`. The bug was that `check_file`'s **verdict ignored them**
and returned `:proven` anyway (a dropped result, not — as first diagnosed — a
Tarjan/`eval` failure). Fixed: the verdict consults the results and returns
`{:error, :liveness_violation, …}`; a condition the evaluator cannot handle
(agent-qualified, compound, `count(...)`) is **refused** (`:unsupported_liveness`)
rather than silently evaluated to `false`. Regression:
`test/features/liveness_verdict_test.exs`. The single-agent compile-time liveness
verifier was already sound.

**F11 — coverage was blind to timer/timeout/resilience handlers (RESOLVED).**
`Vor.Simulator.Coverage` marked a handler reached only via *received message*
telemetry; a `state_timeout` handler receives no message and was reported
`missing` even when it fired. Fixed: coverage consumes the new
`[:vor, :monitored, :resilience_fired]` event and records the handler tag —
reached when it fires, correctly unreached when the deadline never fires.
Periodic (`every`) timers live in a separate `periodic_timers` list, not the
declared handler surface, so they had no false-missing (separate, non-defect gap).

**F13 — the monitored/resilience tier had no violation-reporting path (RESOLVED).**
`monitored(within:)` only *recovered* at runtime and emitted nothing. Fixed:
codegen emits `[:vor, :monitored, :deadline_exceeded]` / `:resilience_fired`
(with `restores_target`), and `Vor.Simulator.MonitoredWatch` turns a
deadline-exceeded-without-restoring-a-good-state into a reported violation, while
a healthy recovery is surfaced as `deadline_exceeded → recovered`. **Scope note:**
the monitored condition is per-agent-*state*, so it catches a recovery that fails
to restore the agent's state, but *not* a dropped job (sabotaging the requeue
while keeping the idle transition leaves the worker recovered) — that is a
per-**job** loss (F14), which the monitored tier structurally cannot see.

**F9 / F12 — codegen crashes replaced with working support (RESOLVED).** A
single-value enum state (`state phase: :running`) now compiles as a one-state
gen_statem; a parameterised send target (`send peer {…}`) resolves the param from
the data map and routes correctly. Both were raw `erl_lint` `unbound_var` crashes.
Regression: `test/features/codegen_diagnostics_test.exs`.

**F1 correction / F14 still open.** F1 is narrower than first stated: cross-field
integer **equality** (`never(exists Q where Q.completed != Q.dispatched)`) *is*
expressible and substantive; the wall is inequalities/arithmetic (`>`, `<`, `+`).
F8 does not block an agent with an incoming connection. **F14 (open):** per-**job**
properties ("every job completes", "no job done twice") are data-indexed and
inexpressible — a language-design question, not a bug.
