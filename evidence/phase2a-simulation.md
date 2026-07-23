# Phase 2a — Seeded controllable simulation rediscovers the Raft bug

The model checker reached its honest limit: a fast bug-finder that can't
exhaustively verify BEAM coordination at scale (interleaving explosion; sound POR
and symmetry both ~1×, see `evidence/phase3c-por-measurement.md`). This is the
first step of the pivot to **simulation testing** — running the real
implementation, which is **structurally vacuity-proof**: there is no abstract
model to be empty, so the failure that killed the paper (a proof over a state
space where the property's subject can't exist) *cannot* happen here.

**Milestone — achieved.** Seeded simulation drove three real Raft BEAM processes
into the *same* leader-uniqueness violation the model checker found analytically —
two leaders in different terms — and **replays it from the seed at 100%.**

## Reproduction metadata

| | |
|---|---|
| **Date** | 2026-07-22 |
| **Baseline** | commit `cc41430` (`main`) |
| **Fixture** | `test/fixtures/raft_global_sim.vor` (Raft with the *global* `never(count(role == :leader) > 1)` — the mis-specified invariant the checker refuted) |
| **Milestone seed** | **12** (also 8, 9, 10, 13, 14, 16, 17, 18) |
| **Command** | `mix vor.simulate test/fixtures/raft_global_sim.vor --seed 12 --partition --duration 12000 --fault-interval-min 500 --fault-interval-max 1200 --partition-dur-min 2000 --partition-dur-max 3500 --check-interval 200` |
| **Flavor** | (B) seeded controllable simulation — real BEAM processes, seeded inputs; **no** scheduler control |

---

## 1. Determinism audit (the honest baseline)

Before this phase, `mix vor.simulate` printed a seed and claimed
"seed-reproducible". It was not: `:rand.seed/2` was called **only in the main
process** (`simulator.ex`), but every decision that shapes a run happens in
separate `Task.async` / proxy processes that **do not inherit** that seed. The
recorded seed controlled essentially nothing.

| Decision / non-determinism source | Seeded before? | After 2a.2 | Controllable? | Residual leak |
|---|---|---|---|---|
| Fault **type** (kill/partition/delay) — `Enum.random` | ❌ (fault Task) | ✅ (Task re-seeded) | via flags | — |
| Fault **target** (which agent) — `Enum.random` | ❌ | ✅ | — | — |
| Fault **timing** interval — `:rand.uniform` | ❌ | ✅ (sequence) | range via flags | wall-clock: *when* it lands vs. real processes |
| Partition/delay **duration** — `:rand.uniform` | ❌ | ✅ | range via flags | — |
| Partition **mechanism** (proxy drop-all) | ✅ deterministic | ✅ | yes | — |
| **Workload** contents/timing — `Enum.random` | ❌ (workload Task) | ✅ (Task re-seeded) | rate via flags | wall-clock |
| Proxy **delay** pick / **drop** prob — `Enum.random` / `:rand.uniform` | ❌ (proxy procs) | ❌ | policy via flags | **unused for partitions**; would need per-proxy seeding |
| **BEAM scheduler** interleaving of real processes | ❌ | ❌ | ❌ (it *is* the runtime) | **fundamental** |
| Real **OTP election timers** (state timeouts) | ❌ | ❌ | timeout via params | **fundamental** (wall-clock) |
| Invariant-check **sampling** time | interval only | interval via flag | — | may miss a transient overlap |
| `make_ref` / PIDs | ❌ | ❌ | ❌ | not outcome-affecting for role/term |

## 2. Seeded inputs made total (2a.2)

`Vor.Simulator` now re-seeds each Task's own `:rand` from the run seed with a
per-Task offset (`seed_process/2`), so the **fault schedule** (type, target,
timing, duration) and the **workload** are deterministic functions of the seed.
Verified: two runs of seed 7 produced the identical partition sequence
(`[:node3]` both times); seed 9 produced `[:node3, :node1]`. The seed now
controls the inputs.

**Explicitly out of reach (documented, not fought):** the BEAM scheduler's
fine-grained interleaving of the real processes, real OTP timer firing (wall-clock
driven), and proxy delay/drop randomness (not exercised by the partition-based
bug). These are the residual non-determinism.

---

## 3. The bug, on real processes (2a.3)

```console
$ mix vor.simulate test/fixtures/raft_global_sim.vor --seed 12 --partition \
    --duration 12000 --fault-interval-min 500 --fault-interval-max 1200 \
    --partition-dur-min 2000 --partition-dur-max 3500 --check-interval 200
  ✗ FAIL — violation: "at most one leader"
    node1: … current_term=4 … role=:leader … voted_for=:node1
    node2: … current_term=5 … role=:leader … voted_for=:node2
    node3: … current_term=5 … role=:follower … voted_for=:node2
```

Two live processes are **both** `role == :leader` — `node1` at **term 4**,
`node2` at **term 5**. `node1` is a *stale leader*: it won term 4, was then
partitioned (its proxy dropped all traffic), so the majority on the other side
(`node2` + `node3`) elected `node2` at term 5. `node1` hasn't yet received a
term-5 message to step it down. This is read directly from live process state via
`:sys.get_state` — nothing abstract.

**Search:** across seeds 1–20 with this config, **9 seeds reproduced the
violation** (8, 9, 10, 12, 13, 14, 16, 17, 18); the rest passed. Every violation
was two leaders in **different terms**.

## 4. Cross-validation of the model checker (2a.2/3)

| | Model checker (Phase 3a) | Seeded simulation (this phase) |
|---|---|---|
| method | analytic BFS over an abstract model | real BEAM processes under seeded partitions |
| finding | `never(count(role==:leader) > 1)` violated | same invariant violated |
| witness | stale leader@term1 + leader@term2 | stale leader@term4 + leader@term5 (seed 12) |
| class | two leaders, **different terms** | two leaders, **different terms** (every seed) |
| same-term double-election? | never (current_term monotonicity) | **never observed** |

The two methods corroborate: the same mis-specification (a *global* leader-
uniqueness invariant that is too strong for Raft's *per-term* guarantee),
surfaced independently by proof and by execution. **No same-term double-election
was ever seen** — which would have been a genuine Raft safety bug; its absence is
consistent with the per-term invariant being the correct one (and holding).

## 5. Replay — reproduction rate (2a.4)

Each candidate seed, re-run **15 times** with its fault schedule fixed by the
seed:

| seed | reproduced | leader term-sets observed |
|---|---|---|
| **12** | **15 / 15 (100%)** | `[4, 5]` every run |
| **13** | **15 / 15 (100%)** | `[16, 17]` every run |
| **8** | **15 / 15 (100%)** | mostly `[19, 20]`, once `[18, 19]` |

**Reproduction is 100% for a good seed** — even though the BEAM scheduler and OTP
timers are not controlled. Two things make flavor (B) enough here: the seeded
fault schedule reliably partitions a leader, and the detection window (a
2–3.5 s partition sampled every 200 ms) is wide relative to the residual timing
jitter. The residual non-determinism shows only in the *exact* term numbers (seed
8 lands on `[18,19]` vs `[19,20]`), never in *whether* the bug occurs.

---

## 6. The four questions (2a.5)

**1. Did seeded simulation rediscover the Raft leader-uniqueness bug?** **Yes.**
Seed 12 drives real processes to `node1=leader@term4, node2=leader@term5`;
`mix vor.simulate … --seed 12 …` fails with the two-leader violation.

**2. Does it cross-validate the model checker's finding?** **Yes — same class.**
Both find the *global* invariant violated by two leaders in *different terms* (a
legal transient stale leader), and neither ever produces a same-term double
election. Proof and execution agree.

**3. What is reproducible and what isn't?** The **inputs** are now fully seeded
(fault schedule + workload; §2, verified). Replay is **100%** for a good seed
(§5). The **residual** non-determinism — BEAM scheduling, real OTP timers,
proxy delay/drop randomness, the sampling window — perturbs only the exact term
values, not the occurrence of the bug. Crucially, this is all **concrete**: the
verdict comes from live process state, so it cannot be vacuous.

**4. What would flavor (A) buy, and is it needed?** **Not needed for this
milestone.** Flavor (A) — intercepting the scheduler / virtual time for
byte-for-byte determinism — would pin the exact term numbers and guarantee 100%
even with a narrow detection window, but it is very hard on the BEAM (the
scheduler *is* the runtime; controlling it tends to mean not running real OTP
processes — i.e. model checking again). Flavor (B) reached and replayed the bug
at 100% with real processes. **Recommendation: stay with (B).** Revisit (A) only
if a future bug has a detection window too narrow for seeded inputs to hit
reliably — and then with this evidence in hand, not on spec.

---

## Appendix — reproduction

- **Trigger / replay:** the §3 command (`--seed 12`; also 8, 9, 10, 13, 14, 16, 17, 18).
- **Schedule determinism:** run the same seed twice; the `:partition_start` event sequence (isolated agents) is identical.
- **Reproduction rate:** run a seed N times via `Vor.Simulator.run_system/2`; count `{:error, :violation, "at most one leader", …}`.
- **Regression test:** `test/features/seeded_simulation_test.exs` — tries the known-good seeds and asserts the two-leaders-in-different-terms violation is found (tolerant of the residual non-determinism).
