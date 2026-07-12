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

## 1. Timer / resilience transitions are not explored (architectural gap)

The explorer's successor relation, `Vor.Explorer.Successor.successors/3`
(`lib/vor/explorer/successor.ex:41–53`), generates successors from exactly two
sources:

1. delivering a message already pending in the queue, and
2. injecting one representative external message per `accepts` declaration.

It **never** fires:

- `monitored`-liveness timeouts,
- `resilience` block transitions (`on_invariant_violation`, `on_crash`),
- periodic `every` timers, or
- bare timer-atom handlers (`on :some_timer_fired` where the atom is not an
  `accepts` message).

**Consequence: any transition reachable only through such a trigger is dead code
during verification.** A safety invariant over states that can only be entered
via a timer is then **vacuously true** — the checker returns `Proven ✓` over a
state space from which the interesting states are absent.

Affected examples (confirmed by enumerating `stats.state_map`):

| Example | Effect of the gap |
|---|---|
| **Raft** (`examples/raft_cluster.vor`, `examples/raft.vor`) | Election is timeout-driven. Reachable roles = `{:follower}` only; `vote_count ≡ 0`; the majority gate is never evaluated. A "leader uniqueness" invariant checks "at most one leader" over a space in which **no leader can exist**, so it is **vacuously true** — the reported "1,001 states" contain only followers. |
| **Circuit breaker** (`examples/circuit_breaker.vor`) | Recovery is `on :timer_recovery_fired`, a timer event not in `accepts`. `:half_open` is provably **unreachable**; the probe/recovery subtree is dead code. Reachable phases = `{:closed, :open}`. |
| **G-Counter** (`examples/gcounter.vor`, `examples/gcounter_cluster.vor`) | Gossip runs on `every sync_interval_ms do broadcast {:sync, ...}`. The `every` timer never fires, so **cross-node convergence is never exercised**. |
| **Lock** (`examples/lock.vor`) | **Not affected** — `:free`/`:held` are both reachable via `{:acquire}`/`{:release}` messages. The `monitored`/`resilience` auto-release never fires but is redundant with the message-driven release. |
| **Rate limiter** (`examples/rate_limiter.vor`) | **Not affected** — no timers; fully message-driven. |

The affected `.vor` files carry a prominent `⚠️ KNOWN LIMITATION` header.

**Status:** not fixed. Firing timers/resilience as nondeterministic successors
will change every multi-agent state count, so it should be a deliberate change.
Do **not** work around it by re-modeling an example so it dodges the gap — that
re-hides the defect.

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

The docs describe multi-agent verification as fast and bounded. Once the model is
made non-vacuous (e.g. by making Raft's election reachable as an injectable
event), multi-agent exploration **blows past 200,000 states and truncates** at
the documented bounds (`integer_bound: 3, max_queue: 10, depth: 10`), returning a
truncated (not exhaustive) result. The **1,001-state figure was small because the
model was empty** — see issue #1. Realistic multi-agent bounded model checking of
these protocols is not currently tractable at the documented bounds.
