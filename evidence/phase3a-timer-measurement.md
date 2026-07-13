# Phase 3a — Fire timers, then measure

Phase 1 gave Vor the ability to *report* that a verification result was vacuous.
It did not fix the cause: the explorer's successor relation never fired timer-,
timeout-, or resilience-triggered transitions, so any behavior behind such a
trigger was dead code during verification.

Phase 3a closes that gap — timers now fire as nondeterministic successors — and
then answers the question everything downstream depends on:

> **Once the model is honest, does Vor's multi-agent model checker verify
> anything meaningful within tractable bounds?**

**The headline result: it does — and the first thing it verifies, it refutes.**
With election now reachable, Raft's shipped "at most one leader" invariant is
**VIOLATED**, with a concrete counterexample, found in **0.16 s**.

## Reproduction metadata

| | |
|---|---|
| **Date** | 2026-07-12 |
| **Baseline (before 3a)** | commit `44f04e5` (`main`) |
| **This commit** | the Phase 3a commit on `main` that adds timer firing + this report |
| **Headline command** | `mix vor.check examples/raft_cluster.vor` |
| **Change** | timers fire by default; `--no-fire-timers` restores the old blind mode |
| **Measurement engine** | `Vor.Explorer.check_file/2`, symmetry off unless noted |

Reproduce: `mix vor.check examples/raft_cluster.vor` (fails with a two-leader
counterexample). The frontier numbers below come from `check_file/2` at the
stated bounds; a runnable script is described in the appendix.

---

## 1. What changed

The successor relation gained a third source alongside message-delivery and
external-injection (`lib/vor/explorer/successor.ex`):

1. **Internal-trigger handlers** — any `on {...}` whose tag is not an `accepts`
   message is fired by a timer/timeout/resilience event (monitored-liveness
   timeouts and bare timer atoms like `on :timer_recovery_fired` both lower to
   such handlers). The trigger message is injected; the handler's own guard
   gates it. This is the standard model-checking treatment of a timer: an
   always-enabled nondeterministic action, sound and if anything more
   adversarial than reality.
2. **Periodic `every` timers** — their body actions run via the simulator.

A firing that produces no state change is dropped by the existing
same-as-parent / fingerprint dedup, so a self-looping timer cannot diverge.
(One supporting fix: the simulator now evaluates `in` / `not_in` guards, so the
election-timeout guard `role not_in [:candidate, :leader]` actually filters
instead of collapsing to `:unknown`.)

**Sanity check (required before measuring):** with timers on, Raft's `role`
reaches `:candidate` and `:leader`; `vote_count` reaches 2. With
`--no-fire-timers` it stays `{:follower}` only. Confirmed.

---

## 2. The headline finding — leader uniqueness is VIOLATED

```console
$ mix vor.check examples/raft_cluster.vor
  ✗ Violation: "at most one leader"
  Step 0: Initial state
  Step 1: {:timer, :node1, :liveness_timeout_election_progresses}
  Step 2: Deliver :request_vote from node1 to node2
  Step 3: Deliver :vote_granted from node2 to node1      node1 → leader, term 1
  Step 4: {:timer, :node2, :liveness_timeout_election_progresses}
  Step 5: Deliver :request_vote from node2 to node3
  Step 6: Deliver :vote_granted from node3 to node2      node2 → leader, term 2
  ** (Mix) Vor check failed: {:violation, "at most one leader", ...}
```

**Counterexample (small-bounds run, trace length 9):**

| step | event | node1 | node2 | node3 |
|---|---|---|---|---|
| 1 | node2 election timeout | follower/t0 | **candidate**/t1/v1 | follower/t0 |
| 3 | node3 grants vote | follower/t0 | **leader/t1/v2** | follower/t1 |
| 6 | node3 election timeout | follower/t1 | leader/t1 | **candidate**/t2/v1 |
| 8 | node1 grants vote | follower/t2 | **leader/t1** | **leader/t2** |

**Analysis — this is a mis-specified invariant, not a protocol bug.** The two
leaders are in **different terms** (term 1 and term 2). `node2` is a *stale
leader*: it legitimately won term 1, and `node3` legitimately won term 2 (with
node1's vote). `node2` simply hasn't yet received a term-2 message to step it
down — and in this model it *would* step down on such a message (its leader
handlers demote on a higher term). Raft's actual safety guarantee is **at most
one leader per term**, not globally; a stale leader coexisting with a newer one
is legal, transient Raft behavior.

So the invariant `never(count(agents where role == :leader) > 1)` as written is
**globally too strong**. This is exactly the kind of over-strong specification an
honest model checker should catch — and Vor's does, in a fraction of a second.
(Vor's invariant language cannot currently express per-term uniqueness —
`count(agents where role == :leader and current_term == T)` quantified over `T`
— so the corrected property is not directly checkable here. Flagged.)

We also confirmed same-term double-election does **not** occur: granting a vote
bumps `current_term` to the candidate's term, so a second request in the same
term is denied regardless of `voted_for` (which the abstraction drops). The
violation is genuinely the different-term transient, not an abstraction artifact.

---

## 3. The frontier — how big does the honest model get?

Exhaustive exploration of Raft with a *holding* invariant
(`never(count(role == :leader) > 5)`, so exploration runs to completion), timers
on, symmetry off:

| config | verdict | states | depth | wall-clock |
|---|---|---|---|---|
| q2 ib2 d40 | **proven (truly exhaustive**, natural depth 26) | **11,165** | 26 | **0.68 s** |
| q2 ib2 d12 | proven (depth-capped) | 4,534 | 12 | 0.29 s |
| q3 ib2 d12 | proven (depth-capped) | 66,601 | 12 | 2.85 s |
| q4 ib2 d12 | proven (depth-capped) | 537,579 | 12 | 26 s |
| **q10 ib3 d10 (old reference)** | **did not finish** | >millions | — | **> 60 s (explosion)** |

The **message-queue bound drives the explosion**: each +1 queue slot multiplies
the state count ~8–15× (q2→11k, q3→67k, q4→538k). The old "reference" config
(q=10) is intractable. The old vacuous result was small (1,001 states) *only
because the model was empty* — all followers, few message shapes in flight.

Finding the **violation** is cheap at any config, because BFS reaches the shallow
(depth-8) counterexample before the space blows up:

| config | leader-uniqueness verdict | states | wall-clock |
|---|---|---|---|
| q2 ib2 d12 | VIOLATED (trace 9) | 2,014 | 0.16 s |
| q10 ib3 d10 (old reference) | VIOLATED (trace 7) | 20,705 | 0.63 s |

**Symmetry reduction on the honest model** (q2 ib2 d40): 11,165 → 5,581 states,
a **~2× reduction** — far less than the 8× advertised on the vacuous model,
because the honest space has many asymmetric states (distinct per-node terms and
roles). (Symmetry remains unsound — Phase 3b — so this is a data point, not a
result to rely on.)

---

## 4. The other examples

| Example | Before 3a | After 3a (timers on) |
|---|---|---|
| **circuit_breaker** | `:half_open` unreachable, VACUOUS | `:half_open` **now reachable** (recovery timer fires); all three phases explored |
| **gcounter / gcounter_cluster** | gossip never fires | gossip `every` timer **now fires** (8 → 3,260 states); **but** `counts` map ops still abstract to `:unknown`, so actual convergence *content* is not verified — a separate limitation, not the timer gap |
| **lock** (control) | substantive | unchanged — `{:free, :held}`, 4 states |
| **rate_limiter** (control) | clean | unchanged — 2 states, no timers |

The controls did not move; the two previously-vacuous cases came alive.
**G-Counter caveat:** firing gossip makes convergence *reachable* but not
*checkable* — map operations return `:unknown`, so a "replicas converge"
invariant still cannot be evaluated. That is a distinct abstraction limitation to
address separately.

---

## 5. The four questions

**Is implementation-level bounded model checking of BEAM coordination tractable
enough to be useful?** *Partially.* Finding a **violation** is cheap and useful:
Raft's real counterexample surfaces in 0.16–0.63 s at every config tried,
including the old reference bounds. **Exhaustive** verification of a holding
property is tractable only at small bounds (q≤3: sub-3-seconds; q=4: ~26 s;
q≥10: intractable). So it earns its place as an **opt-in deep check at small
configurations and for bug-finding**, not as a whole-space prover at realistic
bounds.

**Does "verification during ordinary compilation" survive for multi-agent
checking?** *No — as predicted.* Even sub-second exhaustive runs require tiny
bounds (q=2); the old reference config explodes past minutes. Multi-agent model
checking is a CI/opt-in operation (seconds–minutes at best), not a
milliseconds-during-`mix compile` operation. The compile-time claim holds for
single-agent checking only.

**Is partial-order reduction worth building?** *Yes — the bottleneck is squarely
message-interleaving explosion.* The state count is dominated by the queue bound
(~10× per slot), which is exactly what POR targets. This is the highest-value
next investment for the model checker.

**Is the symmetry fix worth building?** *Marginal, and lower priority than POR.*
On the honest model symmetry buys only ~2× (vs the 8× on the vacuous model), and
it is currently unsound. Worth doing eventually, but POR should come first.

---

## 6. Verdict

The honest model checker is **useful for bug-finding at any scale and for
exhaustive proof at small scale**, and **not** a compile-time whole-space
verifier. Its first honest run on the flagship example found a real
specification defect (an over-strong leadership invariant) in 0.16 s. The path
forward is **partial-order reduction** (the interleaving explosion is the wall),
then optionally a **sound symmetry** reduction.

This is a legitimate, publishable measurement: implementation-level bounded model
checking of BEAM coordination pays off as an opt-in deep check and a bug-finder,
not as free verification folded into compilation.

---

## 7. The corrected invariant — Vor's first substantive verification result

The §2 violation was a *mis-specification*, not a protocol bug: Raft guarantees
at most one leader **per term**, and a stale leader from an earlier term may
legitimately coexist with a newer one. Vor's invariant language *can* express the
correct property — a pairwise existential over agents:

```
safety "at most one leader per term" proven do
  never(exists A, B where A.role == :leader and B.role == :leader
                          and A.current_term == B.current_term)
end
```

Cone-of-influence keeps `current_term` in the tracked set
(`tracked = {role, current_term, vote_count}`), so the comparison is evaluated on
concrete term values, not `:abstracted`.

**Result — PROVEN and substantive, and stable across term bounds.** Timers on,
symmetry off, holding property so exploration runs to completion:

| config | verdict | relevance | states | depth | wall-clock |
|---|---|---|---|---|---|
| q2 ib2 | **proven** (truly exhaustive) | **substantive** (8,536 / 11,165 states have a leader) | 11,165 | 26 | 0.69 s |
| q2 ib3 | **proven** (exhaustive) | substantive (26,689 / 36,634) | 36,634 | 32 | 2.04 s |
| q2 ib4 | proven (depth-capped) | substantive (78,094 / 104,904) | 104,904 | 40 | 6.11 s |
| q3 ib2 | proven (exhaustive) | substantive (431,089 / 559,130) | 559,130 | 34 | 37.6 s |

**Term-saturation ruled out.** The invariant compares terms for equality, so
`integer_bound: 2` (terms saturate at 2) was the primary false-violation risk.
The verdict is **stable — proven at ib2, ib3, and ib4** — so it is not a
saturation artifact. And with `--no-fire-timers` the same invariant is correctly
**vacuous** (0 / 28 states have a leader), confirming the relevance verdict
tracks real leader reachability rather than rubber-stamping.

**This is Vor's first real, non-vacuous, substantive multi-agent verification
result:** a property that holds, over a state space in which the constrained
entity (an elected leader) genuinely arises.

> **The framing, recorded durably because it is the point.** The originally
> shipped invariant was **wrong**, and it was **never exercised** — the empty
> (timer-off) model hid the mis-specification. Only when the model became honest
> did the checker reveal that the specification did not match Raft's actual
> guarantee. **The implementation was correct. The specification was not.** A
> verifier is only as good as the properties it is asked to check *and* the
> reachability of the behavior those properties constrain — Vor now measures both
> axes (strength × relevance) and enforces both.

---

## Appendix — reproduction

- **Substantive proof (the shipped, corrected per-term invariant):**
  `mix vor.check --max-queue 2 --integer-bound 2 --depth 40 examples/raft_cluster.vor`
  → `✓ Proven` + `substantive`. (The default bounds, `--max-queue 10`, truncate:
  `~ Bounded`, still substantive — the honest space explodes; see §3.)
- **Old blind (vacuous) behavior:** `mix vor.check --no-fire-timers examples/raft_cluster.vor` → `✗ VACUOUS PROOF`.
- **The original violation (§2):** temporarily replace the invariant with the
  *global* form `never(count(agents where role == :leader) > 1)` and run at small
  bounds → `✗ Violation` (two leaders, different terms).
- **Frontier / holding-invariant timings (§3):** `Vor.Explorer.check_file(source, max_depth: D, max_queue: Q, integer_bound: IB, max_states: 5_000_000, symmetry: false, allow_vacuous: true)`; wall-clock via `:timer.tc/1`.
- **Tests:** `test/features/timer_firing_test.exs` (timers generate successors; candidate/leader/half_open reachable; gossip fires) and the thrice-flipped regression in `test/features/vacuity_test.exs` — *"REGRESSION: per-term leader uniqueness is PROVEN and substantive (was vacuous, then violated)"*.
