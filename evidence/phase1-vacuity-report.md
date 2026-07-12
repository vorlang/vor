# Vacuity Report — a verification tool catching its own vacuous result

This document is the empirical core of the vacuity work: Vor's model checker,
given the very safety property its examples advertised — "at most one leader" on
a three-node Raft cluster — **refuses to certify it**, because the property is
verified over a state space in which no leader can ever exist. The tool now says
so, loudly, and fails closed.

## Reproduction metadata

| | |
|---|---|
| **Date** | 2026-07-12 |
| **Branch** | `phase1-vacuity-detection` (on top of `phase0-truth-cleanup`) |
| **Baseline (before Phase 1)** | commit `0fd94d3` (`phase0-truth-cleanup` tip) |
| **This file's commit** | the Phase 1 feature commit that adds `lib/vor/explorer/vacuity.ex`, `lib/vor/explorer/coverage.ex`, and this report (branch tip of `phase1-vacuity-detection`) |
| **Headline command** | `mix vor.check examples/raft_cluster.vor` |
| **Table config** | `integer_bound: 3, max_queue: 10, max_depth: 10`, symmetry **off** (8008 states) and **on** (1001 states) |
| **CLI default config** | the headline command uses the task defaults: `--depth 50 --integer-bound 3 --max-queue 10`, symmetry auto — which reduces to 1001 states, depth 10 reached |

To reproduce everything below: `git checkout phase1-vacuity-detection && mix deps.get && mix vor.check examples/raft_cluster.vor`.

---

## 1. What vacuity is, and why "Proven ✓ — 1,001 states" meant nothing

A verifier's guarantee has two independent axes:

- **Strength** — how strong the evidence is (`proven` / `checked` / `monitored`).
- **Relevance** — whether the verification engaged with anything at all.

Vor historically tracked only strength. It reported **`✓ Proven (1001 states, depth 10)`** for the Raft invariant "at most one leader." That result was sound and honest about its bounds — and completely uninformative, because in **all 1,001 explored states every node was a follower.** No node ever became a candidate; no node ever became a leader. The checker proved a property *about leadership* over a space in which leadership cannot occur. The proof was **vacuous**.

The cause is a known modelling gap (see `KNOWN_ISSUES.md §1`): the explorer's successor relation does not fire timer- or timeout-triggered transitions, and Raft's election is timeout-driven, so the election never happens during verification. Phase 1 does not fix that gap — it makes the checker **report** it, by adding the relevance axis and failing closed when a `proven` claim is vacuous.

---

## 2. The reproduction — the tool refusing to certify

```console
$ mix vor.check examples/raft_cluster.vor
Checking examples/raft_cluster.vor...
    Tracked fields:    current_term, role, vote_count
    Abstracted fields: commit_index, log, voted_for
    Integer bound:     3
    Max queue:         10
    Symmetry:          enabled (3 identical agents, 6× reduction)
    Invariant relevance:
      ⚠ at most one leader: VACUOUS — subject (role == :leader) never true in any of the 1001 explored states
    ⚠ agent RaftNode declares `role` values [:follower, :candidate, :leader] but only [:follower] was reached. Unreached: [:candidate, :leader]
    ⚠ handler `on {:vote_granted, ...} when role == :candidate and T == current_term` (RaftNode) was never entered during verification
    ⚠ handler `on {:append_entries, ...} when role == :candidate and T >= current_term` (RaftNode) was never entered during verification
    ⚠ handler `on {:request_vote, ...} when role == :leader and T > current_term` (RaftNode) was never entered during verification
    …  (19 of 22 handlers never entered — every candidate- and leader-guarded one)
    ⚠ monitored_liveness handler for "election progresses" (RaftNode) was never fired. NOTE: the explorer does not fire timer/timeout-triggered transitions (KNOWN_ISSUES.md §1)
  ✗ VACUOUS PROOF: safety "at most one leader" is declared `proven`, but its subject was never reachable in the explored state space.
    A proof over a state space where the property's subject cannot arise is vacuous. Either the model is incomplete (see KNOWN_ISSUES.md §1), or the invariant does not constrain reachable behavior.
    Declare it `checked` to accept a weaker guarantee, fix the model so the subject is reachable, or pass --allow-vacuous to override.
** (Mix) Vor check failed: {:vacuous, "at most one leader", "examples/raft_cluster.vor"}
$ echo $?
1
```

(The middle handler warnings are elided with `…`; the real output lists all 19. Everything else is verbatim.)

---

## 3. Before / after — the same command, the same file

**Before Phase 1** (strength only — this is what shipped):

```console
$ mix vor.check examples/raft_cluster.vor
    …
    Symmetry:          enabled (3 identical agents, 6× reduction)
  ✓ Proven (1001 states, depth 10)
```

**After Phase 1** (strength × relevance): the `✗ VACUOUS PROOF` error in §2, exit code 1.

The proof strength did not change — it is still a sound, exhaustive-within-bounds exploration of 1,001 states. What changed is that the tool now reports those 1,001 states contain no leader, so the leadership claim constrains nothing. A vacuous pass no longer looks like a real pass. (You can still get the old green line with `mix vor.check --allow-vacuous examples/raft_cluster.vor`, which prints the same warnings and then `✓ Proven (1001 states, depth 10)`.)

---

## 4. Full results — every example × invariant × (strength, relevance)

Config: `integer_bound: 3, max_queue: 10, max_depth: 10`, symmetry off. Single-agent examples were wrapped in a one-instance system block; invariants marked *(probe)* were injected to exercise the analysis on examples that declare none.

| Example | Invariant | Strength | **Relevance** | Subject reachability |
|---|---|---|---|---|
| **raft_cluster** | at most one leader | `proven` | **VACUOUS** *(fail-closed error)* | `role == :leader` true in **0 / 8008** states |
| **circuit_breaker** | never half_open forwards *(probe)* | `checked` | **VACUOUS** | `phase == :half_open` true in **0 / 2** |
| **lock** | never many held *(probe)* | `checked` | **substantive** | `phase == :held` true in **2 / 4** |
| **gcounter_cluster** | *(none declared)* | — | — | — |
| **gcounter** | *(none declared)* | — | — | — |
| **rate_limiter** | *(none declared)* | — | — | — |

## 5. Declared-but-unreached coverage

| Example | Unreached enum values | Unfired handlers | Unfired resilience / timers |
|---|---|---|---|
| **raft_cluster** | `role`: `:candidate`, `:leader` (only `:follower` reached) | 19 of 22 (all candidate/leader-guarded + the synthesized election-timeout handler) | monitored liveness **"election progresses"** never fired |
| **circuit_breaker** | `phase`: `:half_open` (reached `:closed`, `:open`) | 5 of 9 (all `:half_open`-guarded + recovery) | — (recovery is `on :timer_recovery_fired`, a timer atom) |
| **lock** | *(none — both `:free`/`:held` reached)* | 1 (a queue-path handler) | monitored liveness **"lock released eventually"** never fired |
| **gcounter_cluster** | *(no enum state)* | 0 | periodic timer **`vor_every_0`** (gossip) never fired |
| **gcounter** | *(no enum state)* | 0 | periodic timer **`vor_every_0`** (gossip) never fired |
| **rate_limiter** | *(no enum state)* | 0 | **none** — fully message-driven |

---

## 6. Per-example detail

### The three that fail

**Raft (`examples/raft_cluster.vor`) — VACUOUS.** `role == :leader` is true in **0 of 8008** states (0 of 1001 with symmetry on). `:candidate` and `:leader` are declared but never reached; only `:follower` occurs. 19 of 22 handlers never fire — every handler guarded by `role == :candidate` or `role == :leader`, plus the synthesized election-timeout handler. The monitored-liveness "election progresses" resilience handler — the only path from follower to candidate — is never fired, because the explorer does not fire timer transitions. `vote_count` is pinned at 0 and the majority gate is never evaluated. This is the result that shipped as `✓ Proven (1001 states)`.

**Circuit breaker (`examples/circuit_breaker.vor`) — VACUOUS for any `half_open` property.** `phase` reaches `:closed` and `:open` but never `:half_open`: the only transition into `:half_open` is `on :timer_recovery_fired`, a bare timer atom that is not an `accepts` message, so it is never injected. 5 of 9 handlers never fire (every `:half_open`-guarded handler plus recovery). Any invariant about recovery/probing is vacuous.

**G-Counter (`examples/gcounter.vor`, `examples/gcounter_cluster.vor`) — convergence unexercised.** Gossip runs on `every sync_interval_ms do broadcast {:sync, …}`; the periodic timer `vor_every_0` never fires, so cross-node anti-entropy is never exercised. (These examples declare no enum `state` and no system invariant, so there is no relevance verdict — but the coverage report flags the dead timer.)

### The controls — the check discriminates, it does not fire on everything

**Lock (`examples/lock.vor`) — substantive.** Both `:free` and `:held` are reached via `{:acquire}` / `{:release}` messages, so `phase == :held` holds in 2 of 4 states and a held-lock safety property genuinely engages. The monitored "lock released eventually" timeout never fires (same timer gap), but it is **redundant** with the message-driven release, so no reachable state is lost. One queue-path handler is never entered.

**Rate limiter (`examples/rate_limiter.vor`) — clean.** No timers, no unfired handlers, no unreached enum values. Nothing here is masked by the timer gap.

These two matter: they show the relevance check **discriminates**. It is not a blanket warning that fires on every example — it fires exactly where behavior is hidden behind an unfired trigger, and stays quiet where the model is genuinely exercised.

---

## 7. Five pre-existing tests had encoded the vacuous behavior as expected

When the fail-closed check landed, exactly **five pre-existing tests** started failing — each had been asserting the vacuous result as a success. They were given `allow_vacuous: true` to keep passing. That they existed at all is itself evidence of how invisible the failure was: the test suite had canonized "proves a property over an empty space" as the desired outcome.

| Test | What it asserted | Load-bearing? |
|---|---|---|
| `multi_agent_test`: **"raft cluster reaches exhaustive proven with state abstraction + queue bound"** | Raft reaches `:proven` **exhaustively**, and checks the tracked-field set | **YES — the smoking gun.** This test made "Raft is proven in N states" the explicit success criterion. It encoded the headline vacuous result as the goal. |
| `multi_agent_test`: **"explorer proves invariant for safe single-promotion system"** | `never(count(role == :promoted) > 0)` passes at `proven` | Partly. `:promoted` has no transition into it (dead state), so the "safety" property was trivially true — the test verified nothing about promotion. |
| `multi_agent_test`: **"raft cluster: explorer either proves the invariant or reports a counterexample"** | Explorer returns proven **or** bounded **or** a counterexample (all accepted) | No — a lenient smoke test; its "proven" happened to be vacuous. |
| `multi_agent_test`: **"symmetry reduction shrinks the explored state space"** | `with_symmetry.states < without_symmetry.states`, both `:proven` | No — tests symmetry state counts, but relied on the vacuous proven run to have a result to compare. |
| `symmetry_soundness_test`: **"weakened-majority Raft: does symmetry prune the two-leader counterexample?"** | Even with the majority gate weakened, no leader-uniqueness violation is found | No — a Phase 0 symmetry investigation; "no violation" is a downstream symptom of the same vacuity (candidates unreachable). |

The first row is the one worth dwelling on: a test named *"reaches exhaustive proven"* asserting the vacuous proof was not a bug to be caught but the outcome to be locked in. The relevance axis is what turns that from an invisible success into a visible `VACUOUS`.

---

## Appendix — reproducing each row

- **Headline / fail-closed:** `mix vor.check examples/raft_cluster.vor` (exit 1).
- **Old green result:** `mix vor.check --allow-vacuous examples/raft_cluster.vor`.
- **Full table & coverage:** the numbers above come from `Vor.Explorer.check_file/2` at `integer_bound: 3, max_queue: 10, max_depth: 10`, `symmetry: false` (single-agent examples wrapped in a one-instance `system` block). The regression test `test/features/vacuity_test.exs` — *"REGRESSION: Raft leader-uniqueness is reported VACUOUS, not a clean proof"* — asserts this on the real `examples/raft_cluster.vor` and is the check that would have caught the original bug.
