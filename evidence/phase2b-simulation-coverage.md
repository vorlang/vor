# Phase 2b — Coverage & relevance for simulation

Phase 1 gave the *model checker* a relevance axis: it learned to say "I proved
nothing" when an invariant's subject was unreachable. Phase 2b gives the
*simulator* the analogous capability. The motivating hole:

> **Seed 7 passed in Phase 2a — but its fault injection had died after ~4 kills,
> so that "pass" was under-tested.**

A green result produced by a run that didn't exercise what it claimed. Same
*shape* as model-checker vacuity, different mechanism (there is no empty state
space here — the harness simply degraded). After this phase, that must be
impossible to miss.

This is the **declared-vs-observed** check applied to the simulation tier:
comparing what a program *declares* it can do (`state` enums, `accepts`, `emits`,
handlers, invariants) against what a run *actually reached*. It is only possible
because Vor has machine-readable declarations to compare against — a generic
chaos library wrapping arbitrary Elixir has no schema of intent.

## Reproduction metadata

| | |
|---|---|
| **Date** | 2026-07-22 |
| **Baseline** | branch `main`, on top of commit `fff4dcd` |
| **Sweep seeds** | `[11, 12, 13, 14, 15]` (fixed) |
| **Per-run config** | `duration 4000ms`, `check-interval 400ms`, `fault-interval {600,1200}ms`, partitions on, workload as noted per example |
| **Generator** | `Vor.Simulator.Sweep.run/3` over each example (single-agent examples wrapped in a one-instance `system` block; the agent source is the verbatim example) |
| **Observation channel** | the compiler's existing `:telemetry` stream — `[:vor, :transition]`, `[:vor, :message, :received]`, `[:vor, :message, :emitted]` — consumed by `Vor.Simulator.Coverage`; **no new per-run instrumentation** |

The union numbers below are "reached by **at least one** seed". Never-reached-by-
any-seed is the strong signal: the current fault/workload configuration cannot
exercise that behaviour at all.

---

## 1. The three axes

**Execution integrity (2b.1) — the Seed 7 problem.** Every run now assesses
whether it actually exercised what it claimed. A pass whose harness degraded is
reported as a distinct outcome, **`UNDER-TESTED`**, never as a clean pass. A run
is degraded if a harness component (fault injector, invariant checker, workload)
crashed, if no invariant check ran, or if faults were requested but none were
injected. The Seed 7 case — fault injector dead a quarter of the way in — now
downgrades to `UNDER-TESTED` with the reason spelled out.

```
⚠ UNDER-TESTED — no violation, but the run exercised less than it claimed:
    - fault injection was requested but no faults were injected
```

**Declared-vs-observed coverage (2b.2).** From the live telemetry stream: which
declared enum state values were reached, which handlers fired, which `accepts`
message tags were received, which `emits`/`send`/`broadcast` tags were emitted.

**Invariant relevance (2b.3).** For each invariant, in how many live checks was
its *subject* actually true? A pass over samples where the subject never appears
is **vacuous** — the same word, same meaning as the model checker.

---

## 2. Per-example results

### raft_cluster

Outcomes across 5 seeds: pass=5, under-tested=0, fail=0, error=0.
Union coverage: states **8/9**, handlers **24/27**, accepts **24/24**, emitted **0/9**.

| instance | field | reached | reached values | never reached |
|---|---|---|---|---|
| node1 | role | 3/3 | :candidate, :follower, :leader | — |
| node2 | role | 2/3 | :follower, :leader | :candidate |
| node3 | role | 3/3 | :candidate, :follower, :leader | — |

| invariant | relevance | substantive seeds | subject |
|---|---|---|---|
| at most one leader per term | **substantive** | 5/5 | `∃ A,B: A.role == :leader and B.role == :leader and A.current_term == B.current_term` |

The flagship result: `:leader` is reached and the per-term uniqueness invariant
is **substantive in every seed** — the pass carries evidence it engaged with a
real leader. The `8/9` states union reflects that node2 happened to jump
follower→leader without a candidate sample landing on a check tick in these
seeds; node1/node3 cover `:candidate`. `emitted 0/9` is discussed in §3.

### circuit_breaker — the interesting one

Outcomes: pass=5. Union coverage: states **2/3**, handlers **3/6**, accepts **3/5**, emitted **1/2**.

| instance | field | reached | reached values | never reached |
|---|---|---|---|---|
| cb | phase | 2/3 | :closed, :open | **:half_open** |

| invariant | relevance | substantive seeds | subject |
|---|---|---|---|
| half-open bounded | **VACUOUS** | 0/5 | `phase == :half_open` |

**The anticipated finding, confirmed.** The model checker couldn't reach
`half_open` until Phase 3a taught it to fire timers. Simulation *also* never
reaches it: `half_open` is entered only via `on :timer_recovery_fired`, and the
real agent arms **no** recovery timer — that transition depends on an external
timer message that no workload sends (`:timer_recovery_fired` is not in
`accepts`). So any invariant whose subject is `half_open` is **vacuous in
simulation**, and the coverage report says so instead of printing a green pass.
Per the brief, this is reported, not fixed.

### gcounter_cluster

Outcomes: pass=5. Union coverage: states **0/0**, handlers **12/12**, accepts **12/12**, emitted **9/9**.

No enum state (`counts` is a `map`), so coverage is message-based. Gossip
**does** fire under real timers: every declared handler and every emitted tag
(including the periodic `sync`/`counts` broadcast) is exercised across the sweep.
No system invariant is declared, so relevance is empty — reported honestly rather
than invented.

### gcounter (one-instance wrapper)

Outcomes: pass=5. Union coverage: states **0/0**, handlers **8/8**, accepts **8/8**, emitted **6/6**.
A single node still exercises all its message handlers; the added trivial
invariant (`node_id == :nobody`) is correctly flagged **vacuous** — a control
showing the relevance axis fires on a subject that can never be true.

### lock

Outcomes: pass=5. Union coverage: states **2/2**, handlers **3/4**, accepts **3/3**, emitted **1/5**.

| instance | field | reached | reached values | never reached |
|---|---|---|---|---|
| lk | phase | 2/2 | :free, :held | — |

| invariant | relevance | substantive seeds | subject |
|---|---|---|---|
| held bounded | **substantive** | 5/5 | `phase == :held` |

Both phases reached; the `:held` subject is live — a substantive pass. `emitted
1/5` reflects the reply-path gap in §3 (only bare replies surface).

### rate_limiter

Outcomes: pass=5. Union coverage: states **0/0**, handlers **1/1**, accepts **1/1**, emitted **1/2**.
Single `:request` handler, no enum state, no invariant — a minimal control that
exercises its one declared message.

---

## 3. Honest limitations of the observation channel

The coverage tool surfaces its own blind spots rather than hiding them:

- **`emitted 0/9` for raft_cluster** is *not* "no messages flowed" — the inter-
  node protocol (`request_vote`, `append_entries`, …) is declared under
  `accepts`/`sends`, not `emits`, and those messages are exercised (accepts
  24/24). The declared `emits` tags are the *client replies*
  (`client_ok`, `client_redirect`, `state_info`), which require client requests
  to a leader; they are legitimately under-covered here.
- **gen_statem reply path.** A gen_statem handler that replies (e.g. Raft's
  `client_ok`, lock's `grant`) surfaces on the emitted stream as a generic `ok`
  rather than the declared reply tag. This is a pre-existing telemetry-generation
  detail, not a coverage bug; it means the `emits` axis can under-report for
  reply-heavy protocols. `send`/`broadcast` emissions **are** observed
  accurately (this phase added their telemetry). Reported, not fixed.
- **Enum-only states.** Coverage's state axis only tracks declared enum fields;
  `map`/scalar state (gcounter, rate_limiter) contributes no reachable-state
  count. Those examples are covered on the message axes instead.

---

## 4. What changed

- `Vor.Simulator.Coverage` — telemetry-fed declared-vs-observed collector.
- `Vor.Simulator.Sweep` — union coverage + per-seed outcome counts + union
  relevance across seeds.
- Execution-integrity assessment and the `UNDER-TESTED` outcome in
  `Vor.Simulator` / `mix vor.simulate`.
- Per-invariant relevance recorded from live checks (`subject_active`) and
  aggregated per run and per sweep.
- `send`/`broadcast` now emit `[:vor, :message, :emitted]` telemetry, completing
  the emission-observation channel.

Tests: `test/features/simulation_coverage_test.exs` pins the red→green
guarantees — a crashed / no-fault harness reports `UNDER-TESTED` (not `pass`),
and an invariant whose subject never appears reports `vacuous`.

## 5. The one thing to hold onto

Phase 1's lesson, restated for this tier: **a green result must carry evidence
that it engaged with something.** circuit_breaker's `half_open` pass is now
visibly vacuous; Seed 7's dead injector is now `UNDER-TESTED`. The simulator has
learned to say "I tested less than I claimed."
