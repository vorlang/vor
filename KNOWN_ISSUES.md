# Known Issues

This document records confirmed defects in Vor's verification tooling as of
**July 2026**. The intent is an accurate account a user can rely on, not a
roadmap.

Summary of impact: **single-agent verification, protocol constraints,
backpressure, generated telemetry, and chaos simulation work as described.
Multi-agent bounded model checking does not verify any behavior that is gated
behind a timer, timeout, or resilience handler, and its symmetry reduction is
unsound.** Any multi-agent model-checking result for such behavior is vacuous.

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

## 2. Symmetry canonicalization is not orbit-exact (unsound reduction)

`Vor.Explorer.Symmetry.canonical_fingerprint/1` (`lib/vor/explorer/symmetry.ex:107`)
is intended to pick one representative per orbit under the agent-permutation
group (S₃ for three identical agents). It does not. It performs **three
uncoordinated collapses**:

1. sorts the per-agent states into an unordered multiset (drops which agent holds
   which state);
2. strips the `from`/`to` fields from every pending message and bags the
   payloads; and
3. keeps **payload agent IDs verbatim** (e.g. `voter: :node3`).

Because no single consistent permutation ties these together, the function can
map states lying in **different S₃ orbits** to the **same** fingerprint. Since the
BFS prunes on fingerprint membership (`lib/vor/explorer/explorer.ex:316`), a
state — and any violation reachable only through it — can be **pruned away
unexplored**. This makes the reduction **unsound**, not merely imprecise. (A
correct quotient over S₃ caps at 6× for three agents; any larger reduction factor
indicates over-merging across orbits, not a valid symmetry reduction.)

**Minimal reproduction:** `test/features/symmetry_soundness_test.exs`, the test
`"KNOWN BUG: canonical_fingerprint collides two states from different S3 orbits"`.
It constructs two states with three pairwise-distinct agent roles (trivial
stabilizer) whose only difference is a message recipient, and asserts the current
(incorrect) collision. It is written to start failing once the bug is fixed.

**Correct fix (not done here):** canonicalize under a *single*
permutation π applied consistently to agent names, message endpoints, **and
payload agent IDs**, taking the lexicographically smallest serialization over all
`|S₃| = 6` permutations.

**Status:** not fixed (deliberately deferred — a correct canonicalization will
change multi-agent state counts, so it should be done as a deliberate change).

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

## 4. Multi-agent checking is not tractable at the documented bounds

With timers firing (issue #1 fixed) the honest Raft state space explodes: at the
old reference config (`integer_bound: 3, max_queue: 10, depth: 10`) exhaustive
exploration no longer terminates. It is tractable only at small bounds — queue 2
is fully exhaustive in ~0.7 s (11k states), queue 3 in ~3 s (67k), queue 4 in
~26 s (538k), queue 10 does not finish. The message-queue bound drives an ~8–15×
blow-up per slot. The old **1,001-state figure was small because the model was
empty** (all followers). Full measurement, including wall-clock at each bound, is
in [`evidence/phase3a-timer-measurement.md`](evidence/phase3a-timer-measurement.md).

**Bug-finding remains cheap** — a shallow counterexample (e.g. Raft's two-leader
violation) is found in well under a second even at the old reference config,
because BFS reaches it before the space blows up. So the checker is useful as an
opt-in deep check and a bug-finder, not as free whole-space verification folded
into `mix compile`. The interleaving explosion is the wall; partial-order
reduction is the highest-value next step.

---

## 5. Map operations abstract to `:unknown` (convergence not checkable)

`Vor.Explorer.Simulator` evaluates map operations (`map_put`, `map_merge`,
`map_get`, `map_sum`) to the symbolic value `:unknown`. For the G-Counter
examples this means that, even now that gossip fires (issue #1), the CRDT's
`counts` map never takes a concrete value — so a "replicas converge" invariant
is *reachable* but not *checkable*. This is a distinct limitation from the timer
gap. Protocols whose safety depends on map/collection contents cannot currently
be verified at the value level; enum-state and integer properties are unaffected.
