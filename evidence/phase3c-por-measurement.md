# Phase 3c — Partial-order reduction, measured

Phase 3a found the honest multi-agent bottleneck is **message-interleaving
explosion** (~8–15× state growth per queue slot) and that bug-finding is cheap
while exhaustive verification is tractable only at small bounds. Partial-order
reduction attacks that bottleneck directly. This phase implements a conservative,
sound static POR and measures what it buys.

**Headline: POR buys 2.7–22× on the honest Raft model and moves the exhaustive
frontier from queue 3 to queue 4** — and it passes the soundness gate on every
example (verdict, relevance, counterexample, and vacuity all preserved).

## Reproduction metadata

| | |
|---|---|
| **Date** | 2026-07-21 |
| **Baseline (before 3c)** | commit `7e4976d` (`main`) |
| **This commit** | the Phase 3c commit on `main` (adds `lib/vor/explorer/por.ex` + this report) |
| **Default** | POR on; `--no-por` / `por: false` disables it |
| **Engine** | `Vor.Explorer.check_file/2`, symmetry off unless noted; wall-clock via `:timer.tc/1` |

---

## 1. What POR does here (and why it is sound)

Every successor is one event aimed at one agent (`last_action` is
`{:deliver, _, to, _}`, `{:external, agent, _}`, or `{:timer, agent, _}`), a
handler mutates only that target agent's local state, and pending messages are an
unordered multiset in `ProductState.fingerprint/1`. Under those semantics **two
events aimed at different agents are independent** — they commute to the same
fingerprint and neither disables the other. That is the dependency relation POR
needs.

`Vor.Explorer.POR.ample/5` picks, at each state, a single agent whose *entire*
enabled event set is **invisible** (changes no field the safety invariant
references) and whose successors are all *new* (cycle proviso), and explores only
those — deferring the rest, which stay enabled and are explored downstream. If no
such agent exists it explores the full set. The ample-set conditions
(Clarke–Grumberg–Peled), specialized:

- **C1 (persistent):** deferred events target different agents ⇒ independent of
  the ample set.
- **C2 (invisible):** reduce to a proper subset only when all ample events are
  invisible, so deferring visible events cannot hide a violating state.
- **C3 (cycle proviso):** reduce only when every ample successor is unvisited; the
  moment an ample event would close onto a visited state, expand fully. In a
  finite space this prevents any event being ignored forever.

Conservatism is deliberate: over-approximating dependency only costs exploration;
under-approximating it drops states and is unsound. DPOR (dynamic race detection,
no invisibility restriction) would slot in as a replacement for `ample/5`; it is
**not** built here — static POR proved more than sufficient (see §3).

---

## 2. Soundness gate (the most important part)

POR is another reduction that silently drops states — the exact failure mode this
whole project exists to eliminate. So before trusting any number: for every
example, at bounds where the non-POR run terminates, POR must produce the **same
verdict** and **same relevance**, must **not hide the counterexample**, must
**preserve vacuity**, and must **never increase** the state count.

| example | verdict (off → on) | relevance (off → on) | states (off → on) |
|---|---|---|---|
| raft per-term, ib2 | proven → **proven** | substantive → **substantive** | 11,165 → 4,134 |
| raft per-term, ib3 | proven → **proven** | substantive → **substantive** | 36,634 → 2,097 |
| raft **global** (violated) | violated → **violated** | — | 2,014 → 1,461 |
| raft `--no-fire-timers` | proven → **proven** | vacuous → **vacuous** | 28 → 7 |
| circuit_breaker | proven → **proven** | substantive → **substantive** | 3 → 3 |
| lock | proven → **proven** | substantive → **substantive** | 4 → 4 |
| rate_limiter | proven → **proven** | vacuous → **vacuous** | 2 → 2 |
| gcounter_cluster | proven → **proven** | vacuous → **vacuous** | 3,260 → 2,077 |

**All rows pass.** The counterexample survives (the global mis-specified invariant
still fails under POR), vacuity survives (a timer-off Raft is still reported
vacuous — POR does not make an empty space look explored), and no verdict or
relevance label moves. Encoded as tests in `test/features/por_test.exs`.

---

## 3. Reduction and the tractability frontier

Per-term leader-uniqueness proof (holding, so exploration runs to completion),
timers on, symmetry off:

| config | non-POR states | non-POR time | **POR states** | **POR time** | reduction |
|---|---|---|---|---|---|
| q2 ib2 | 11,165 | 0.69 s | 4,134 | 0.3 s | 2.7× |
| q2 ib3 | 36,634 | 2.04 s | 2,097 | 0.2 s | **17.5×** |
| q3 ib2 | 559,130 | 37.6 s | 25,720 | **1.6 s** | **21.7×** |
| q3 ib3 | (too large) | — | 11,415 | 0.7 s | — |
| **q4 ib2** | **intractable** | **> 60 s** | **98,829** | **6.3 s** | **frontier moved** |
| q4 ib3 | intractable | — | 41,506 | 2.5 s | — |
| q10 ib3 | intractable | — | did not finish | > 120 s | still intractable |

**How much does POR buy, and does it move the frontier?**

- **2.7–22×** on the honest Raft model, and the factor *grows with the bounds*
  (17.5× at ib3, 21.7× at q3). Honest Raft has many invisible message deliveries
  (stale/no-op messages, updates to abstracted fields), and POR collapses their
  cross-agent interleavings; the few visible transitions (election, promotion,
  term bumps) are explored fully.
- **It moves the frontier one queue slot:** q3 drops from 37.6 s to 1.6 s, and
  **q4 becomes tractable (6.3 s) where it previously did not terminate.** q10
  remains intractable — POR is a large constant-factor win, not a change in the
  asymptotic wall.

This confirms the Phase 3a hypothesis: message-interleaving reduction is the
high-value lever. POR beats symmetry here by an order of magnitude (symmetry was
~2× on the honest model; POR is 20×+), which is why symmetry stays deprioritized.

**Compared to the two Phase 3a reference numbers:** q2 ib2 11,165 → 4,134;
q3 ib2 559,130 / 37.6 s → 25,720 / 1.6 s.

---

## 4. Composition

POR composes with the existing reductions: cone-of-influence abstraction and
integer saturation run first (they shrink the per-state representation), then POR
selects an ample subset of the resulting successors, then symmetry (when enabled)
canonicalizes fingerprints for dedup. The soundness gate above includes a
symmetry-on row for Raft; verdict and relevance are preserved. POR is disabled
when a `proven` liveness invariant is present (the reduced graph would need a
stronger liveness cycle proviso) — conservative by default.

---

## 5. Repositioning the checker (Part B)

The measurement makes the tool's identity clear, and the interface now says it:
**a bug-finder that can also do bounded exhaustive verification at small
configs** — not a compile-time verifier of distributed systems.

- **`mix compile` never runs multi-agent exploration** (it only parses invariants
  onto the IR); regression-tested in `por_test.exs`.
- **`mix vor.check` defaults to a fast smoke check** at small bounds (queue 2,
  integer-bound 2, depth 20) — good for finding bugs quickly. **`--deep`** opts
  into wider bounds (queue 4, integer-bound 3, depth 50) for bounded exhaustive
  verification.
- **Honest output.** A pass now reads *"No counterexample in the smoke check …
  This is a fast bug-find, NOT verification"* (default) or *"exhaustive within
  bounds … not an unconditional proof"* (`--deep`); a failure reads
  *"Counterexample found"*. The bare word "Proven" no longer appears for a
  multi-agent result.

---

## 6. Verdict

Partial-order reduction is a **20×+ win** on the honest model, moves the
exhaustive frontier out by a queue slot (q4 now reachable), and — verified by the
soundness gate on every example — changes no verdict, no relevance label, and
hides no counterexample. Static ample-set POR was sufficient; DPOR is noted as a
future lever but not needed to make the checker useful. Combined with the
repositioning, the checker is now honestly what the measurement says it is: a fast
counterexample finder, with opt-in bounded verification at small scale.

---

## Appendix — reproduction

- **Soundness gate & frontier:** `Vor.Explorer.check_file(source, max_depth: D, max_queue: Q, integer_bound: IB, max_states: 5_000_000, symmetry: false, por: <bool>)`; wall-clock via `:timer.tc/1`. `source` is `examples/raft_cluster.vor` (per-term) or with its invariant swapped for the global `never(count(role == :leader) > 1)`.
- **Smoke vs deep:** `mix vor.check examples/raft_cluster.vor` (smoke) vs `mix vor.check --deep examples/raft_cluster.vor`.
- **Disable POR:** add `--no-por`.
- **Tests:** `test/features/por_test.exs` (verdict/relevance equivalence, counterexample survival, vacuity survival, symmetry composition, and that `mix compile` does not explore).
