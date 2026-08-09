# 02 — Job queue with workers (liveness-dominant)

> **Update (2026-08-09 fix round).** F9, F10, F11, F12, F13 are **RESOLVED** — see
> the per-finding notes in §5 and the CHANGELOG. The TLC IOU for `306e5b2` is
> **discharged** (Java available; VorSafetyVerifier 15,934,464 states / 0
> violations, VorGraphExtraction 903 / 0). **Correction:** F10's root cause was
> *not* the Tarjan/`eval` machinery (that works — it detects sinks and cycles); it
> was that `check_file`'s verdict **dropped** the computed liveness result. F14
> (per-job properties) stays open.

## 1. What it models

A job queue. A `Queue` agent accepts `{:submit, job_id}` and dispatches each job
to a worker; 2 `Worker` agents accept an assignment, do the work, and report
`{:done, job_id}` back. A worker that does not finish within a deadline is assumed
stuck; its job should be recovered (requeued) to another worker. The correctness
question is not "which state is an agent in" but **"does every submitted job
eventually complete"** — a *liveness* property, and the load-bearing one.

## 2. What it probes

Probe 1 stressed data-carrying **state**; this probe targets **time**. Every
substantive result Vor has ever produced is a *safety* property. The liveness
machinery (`monitored(within:)`, resilience handlers, `eventually`) is the
least-exercised third of the language, and — per KNOWN_ISSUES — has never been the
load-bearing requirement of any shipped example (the lock's monitored timeout is
redundant; the circuit breaker's recovery was unreachable).

**Hypotheses (stated before the code):**

> **H1** — a system whose correctness is "every submitted job eventually
> completes" can be written with the liveness as the *primary* invariant, and the
> **monitored tier will produce a substantive runtime guarantee under fault** — the
> timeout genuinely fires and the resilience handler genuinely recovers the job.
>
> **H2** — the checker's SCC liveness (`liveness … proven`) will be **unable** to
> prove "every job completes": inexpressible (per-job, not per-state), or vacuous,
> or blocked by bounds — so the *monitored* tier is the only tier that says
> anything about the real requirement.

**Prediction:** H1 holds with friction; H2 holds outright. The brief flagged the
most interesting possible outcome as "the checker proves a substantive per-job
liveness" — that did **not** happen; the opposite did (see F10/F14).

## 3. The program

[`02-jobqueue.vor`](02-jobqueue.vor). The load-bearing declaration is the
per-worker **monitored** liveness plus its resilience handler:

```vor
liveness "worker finishes eventually" monitored(within: deadline_ms) do
  always(phase != :idle implies eventually(phase == :idle))
end

resilience do
  on_invariant_violation("worker finishes eventually") ->
    transition phase: :idle
    send :queue {:requeue, job_id: current_job}
end
```

The natural *system-level* requirement — `liveness "every job completes" proven do
always(job_submitted implies eventually(job_done)) end` — is written as a comment
in the system block, **not** declared, because it cannot be honestly checked
(F10/F14).

## 4. What the tiers reported

**The mechanism works.** A controlled, noise-free runtime test (assign a job, wait
past the 80 ms deadline, send no `finish`) shows the worker self-recover:
`{:busy, :jobA}` at 30 ms → `{:idle, :jobA}` at 280 ms. This is the **first time
the monitored tier's firing path has been exercised by a system that needs it** —
the timeout fires and resilience runs on real BEAM processes. But every *checking*
and *reporting* tier around it is blind or vacuous.

> Relevance is mandatory: a `Proven`/`pass` without `substantive` beside it is a
> finding, not a validation.

| Invariant / property | Tier | Strength | Relevance | Notes |
|---|---|---|---|---|
| `worker finishes eventually` (per-worker-state) | `mix compile`, **agent-level `proven`** | **proven** | **substantive** | Single-agent liveness verifier is sound: a busy-**sink** worker (no finish, no resilience) is **refused** with a teaching message; a worker that can reach idle compiles. But it proves a *weaker* property than the requirement — a worker "drains" by requeuing/dropping, not necessarily by *completing* the job. |
| `worker finishes eventually` | `monitored` (runtime) | **monitored** | **substantive (mechanism), unobservable (tooling)** | Fires and recovers (shown above). But no tier *reports* it: coverage marks the handler `missing` even when it runs (F11); there is no liveness-violation channel (F13). |
| `workers drain` = `always(w1.phase == :busy implies eventually(w1.phase == :idle))` | `mix vor.check`, **system `proven`** (multi-agent SCC) | "proven" | **vacuous** | Returns `proven` **even for a permanently-stuck worker** (F10). No constructed starvation was ever caught at this tier. |
| `every job completes` = `always(job_submitted implies eventually(job_done))` | `mix vor.check`, system `proven` | "proven" (36 states) | **vacuous** | `job_submitted`/`job_done` are undefined identifiers; parsed and "proven" with no error (F14). |
| `never(exists Q where Q.completed != Q.dispatched)` | `mix vor.check`, system `checked` | **checked** | **substantive** | Cross-field integer equality **is** expressible and real — VIOLATION at depth 1 (dispatched leads completed in flight); tautology control proves over 345 states. Refines F1. |
| `never(completed > dispatched)` ("no job done twice") | `mix vor.check` | **inexpressible** | — | Inequalities/arithmetic rejected (`:unexpected_in_invariant`). The property that would catch a double-done cannot be written (F14). |

**Simulation (`mix vor.simulate`).** Happy-path (long deadline, no faults) and
fault runs (short deadline and/or `kill`) both return `:pass`. Coverage across the
sweep:

- `phase` reaches both `:busy` and `:idle` on both workers.
- The resilience handler `liveness_timeout_worker_finishes_eventually` is reported
  `missing` on **every** run — including one where w1 reached `:idle` **without ever
  receiving `:finish`**, which is only possible *via* the timeout resilience. So the
  handler fired and coverage still called it unexercised (**F11**).

**Mutation tests (both mandatory; recorded honestly — neither goes red).**

1. **Break recovery** — resilience transitions to idle but no longer requeues (job
   silently dropped); also tested with resilience removed entirely. Controlled run:
   worker recovers to `:idle`, `current_job` still set, **no requeue, no `done`, no
   signal**. Full simulator, faults on, seeds 1/2/7: **all `:pass`, not degraded**,
   2–3 faults injected each. **No tier catches broken recovery** — because the
   `.vor` has no *expressible* system invariant asserting the requirement (F14) and
   the monitored tier has no violation channel (F13). This is the headline the brief
   anticipated: *"If it stays green, the monitored tier isn't watching."*
2. **Break safety** ("no job done twice") — the catching invariant `never(completed
   > dispatched)` is **inexpressible** (F14, inequality wall). The mutation cannot be
   set up against any tier, so it cannot be made red.

## 5. Findings (continuing F1–F8 from Probe 1)

- **F9 — A single-value enum state field crashes codegen.** `state phase: :running`
  (one value) generates code referencing an unbound gen_statem state variable
  (`unbound_var :Phase`), surfaced as a raw Erlang `erl_lint` error, not a Vor
  diagnostic. Hit three times (`Queue`'s `:running`, a driver's `:on`). Route-around:
  use a ≥2-value enum or drop the field. **Error quality: terrible** — a raw
  compiler-internals leak for a plausible thing to write.
  **RESOLVED (2026-08-09):** `is_enum_type?` now accepts a single atom, so it
  compiles as a one-state gen_statem (it used to fall through to a data field whose
  atom default was silently dropped). Regression: `codegen_diagnostics_test.exs`.

- **F10 — System-tier `liveness … proven` (multi-agent SCC) is non-substantive.**
  I could not construct a single multi-agent system whose `liveness … proven`
  reports a violation. A worker that becomes `busy` and can never become `idle`
  (a genuine deadlock) → **`proven`**; a two-agent ping-pong that loops forever
  without reaching a target state → **`proven`** (both with agent-qualified *and*
  bare conditions). Two code-level causes are visible: (a) `Tarjan.find_sccs`
  discards trivial SCCs (`size > 1 or self-loop`), and terminal states get no
  stuttering self-loop, so a deadlock sink is *never examined*; (b)
  `LivenessChecker.eval_product_condition` matches only bare `field op :value`
  ("any agent") and `count(...)`, silently returning `false` for agent-qualified
  conditions like `w1.phase == :busy`, so those obligations never register. The
  bare-condition livelock also returned `proven`, so at least one further factor
  (likely the cycle not re-forming an identical product-state under the bounded
  queue) is in play — not fully isolated. What is certain: **this is a
  green-but-empty at the check tier, the exact pattern the project exists to
  catch**, one tier over from F3. *Contrast:* the **single-agent compile-time**
  liveness verifier IS sound — it refuses the same deadlock with a teaching
  message.
  **RESOLVED (2026-08-09) — mechanism above was wrong.** The detection works:
  `check_terminal_liveness` examines sinks and the SCC check finds cycles, and
  both cases *did* write a `{:violation, …}` into `stats.liveness.results`. The
  actual bug was that `check_file`'s verdict **ignored the results** and returned
  `:proven` (a dropped result, not the Tarjan/`eval` gaps hypothesised here). The
  verdict now consults them; unevaluable agent-qualified/compound/`count`
  conditions are **refused** (`:unsupported_liveness`) rather than silently proved.
  Regression: `liveness_verdict_test.exs`.

- **F11 — Coverage is structurally blind to timer / timeout / resilience
  handlers.** `Simulator.Coverage` compares declared handlers against **received
  message tags** (`coverage.ex:164`, `handlers: cmp(decl.handlers, obs_received)`).
  A `state_timeout` handler receives no message, so
  `liveness_timeout_worker_finishes_eventually` can never enter `obs_received` and
  is **always** reported `missing`, even when it demonstrably fires. This is worse
  than the brief's "does it cry wolf on a correctly-unexercised handler?" — it
  *cannot see* the handler at all, so it cannot distinguish "correctly unexercised
  on the happy path" from "fired and recovered a job." Blind on exactly the tier
  this probe targets.
  **RESOLVED (2026-08-09):** coverage consumes the new
  `[:vor, :monitored, :resilience_fired]` event and records the handler tag, so a
  fired resilience handler is marked *reached* and (correctly) *unreached* when the
  deadline never fires. Regression: `monitored_channel_test.exs`.

- **F12 — A dynamic/parameter send target crashes codegen.** `send peer {…}` where
  `peer` is an agent parameter generates `unbound_var :Peer` (raw `erl_lint`). Only
  **literal atom** targets (`send :queue {…}`) compile. Directly answers a brief
  question — *can resilience requeue to a different, dynamically-chosen worker?*
  **No**; you can only requeue to a hardcoded name (the program requeues every
  timed-out job to `:w2`). **Error quality: terrible.**
  **RESOLVED (2026-08-09):** `send peer {…}` now resolves the param from the data
  map and routes correctly — a resilience handler *can* requeue to a
  dynamically-chosen worker. Regression: `codegen_diagnostics_test.exs`.

- **F13 — The monitored / resilience tier has no violation-reporting path.** At
  runtime, `monitored(within:)` only *recovers*: on the deadline it force-transitions
  to the target state (`lowering.ex:672` — an empty resilience defaults to
  `transition → target_state`; a resilience handler *adds* side-effects). It never
  emits a violation, and `mix vor.simulate` only checks **system** safety invariants,
  not agent-level monitored liveness. So a broken recovery degrades the system
  silently — there is no tier at which "the deadline was missed" becomes an
  observable failure. (Subtle corner: a *non-empty* resilience handler *replaces* the
  default, so one that forgets `transition phase: :idle` would leave the worker stuck
  — the default safety net only applies when resilience is empty.)
  **RESOLVED (2026-08-09):** codegen emits `[:vor, :monitored, :deadline_exceeded]`
  / `:resilience_fired` (with `restores_target`), and `Vor.Simulator.MonitoredWatch`
  reports a violation when a deadline is exceeded and the recovery does not restore
  a good state; a healthy recovery is surfaced as `deadline_exceeded → recovered`.
  **Scope (a conflict with the fix-round brief, flagged not papered over):**
  because the monitored condition is per-worker-*state*, sabotaging the *requeue*
  while keeping the idle transition does **not** go red — the worker recovers; the
  dropped *job* is a per-job loss (F14) the monitored tier cannot see. The red case
  is a recovery that fails to restore the worker's state.
  Regression: `monitored_channel_test.exs`.

- **F14 — "Every job completes" / "no job done twice" are inexpressible; the checker
  refinement of F1.** The requirement is per-**job** (data-indexed, quantified);
  the grammar is per-agent-**state**. Concretely: the compile tier is single-agent
  (cannot span queue+workers) and refuses value invariants (F3); at the system tier,
  the per-job form `always(job_submitted implies eventually(job_done))` parses over
  **undefined identifiers** and returns `proven` with no error (silent vacuity), and
  the safety form `never(completed > dispatched)` is rejected (no inequalities). **But
  F1 is narrower than Probe 1 stated:** cross-field integer **equality** *is*
  expressible and substantive — `never(exists Q where Q.completed != Q.dispatched)`
  genuinely violates when the counters diverge. The wall is **inequalities and
  arithmetic** (`>`, `<`, `+`), which is exactly what "no double-done"
  (`completed ≤ dispatched`) needs — so it can't be written.

- **F15 (accuracy) — F8 does not block an agent with an incoming connection.** The
  `Queue` was driven substantively by the explorer (345 states; a submit is
  injected, `dispatched` increments). F8's "driverless agent not exercised" applies
  only to agents with *no* incoming connection and no client; a queue wired to
  workers is fine.

## 6. Verdicts

- **H1 — holds at the mechanism level, fails at the tooling level.** The monitored
  timeout genuinely fires and resilience genuinely recovers a job on real BEAM
  processes (first time ever, for a system that needs it). But: (a) the "fault" the
  tier survives is a *slow/wedged* worker (the deadline), **not a crash** — a
  `kill`ed worker's in-flight job is simply lost, since its resilience cannot run in
  a dead process and the queue never learns; (b) coverage cannot observe the handler
  firing (F11); (c) no expressible invariant asserts the requirement (F14), so the
  simulator is vacuously green; (d) breaking recovery is undetectable at every tier
  (F13). The guarantee is real; **the tooling cannot testify to it, and cannot tell
  working from broken.**

- **H2 — confirmed, and the interesting outcome triggered in reverse.** The checker
  cannot prove "every job completes." Per-job is inexpressible (silently vacuous on
  undefined identifiers). The expressible per-state proxy is sound **only** at the
  single-agent *compile* tier — where it cannot span agents — and **non-substantive**
  at the multi-agent *check* tier (F10). The brief asked to record prominently if the
  checker proved a substantive per-job liveness; instead it **proves per-state
  liveness vacuously**, which is the F3 pattern at the check tier. The monitored tier
  is indeed the only one with a real relationship to the requirement — and even it
  has no reporting channel (F13).

## 7. Recommendation for the agent probe (next)

Warn the agent about, in priority order:

1. **Silent vacuity on liveness.** An agent will write the natural per-job liveness,
   see `proven`, and believe it (F14); or write a system `liveness … proven`, see
   `proven`, and ship a wedgeable system (F10). There is no relevance label on the
   check-tier liveness result. This is the highest-risk trap.
2. **Two hard codegen crashes with raw Erlang errors** for plausible code: a
   single-value enum (F9) and a parameterised send target (F12). An agent will write
   both and get an incomprehensible `unbound_var` instead of a Vor diagnostic.
3. **Coverage under-reports the resilience tier** (F11): an agent reading "resilience
   handler unexercised" will wrongly conclude it must add a test, when the handler
   in fact fired.
4. **The monitored tier is fire-and-forget** (F13): recovery has no failure signal,
   so an agent cannot get feedback that its resilience logic is wrong.

The good news to preserve: the **single-agent compile-time liveness refusal** and
the **F3 fail-closed value refusal** are exactly the teaching errors an agent needs.
The gap is that their multi-agent / runtime counterparts don't exist yet.

## 8. Reproduction

- **Commit:** this commit on `main`. **Program:** `usecases/02-jobqueue.vor`.
- **Monitored tier fires (H1 mechanism):** compile with `deadline_ms: 80`, start via
  `Vor.Simulator.compile_for_simulation/1` + `SupervisorBuilder.start_link/1`, resolve
  the real worker pid through `MessageProxy.get_real_pid/1`, `:gen_statem.cast(w1,
  {:assign, %{job_id: :jobA}})`, sleep 280 ms without sending `:finish` →
  `:sys.get_state/1` shows `{:idle, …}`.
- **F10 (check-tier vacuity):** a `Worker` whose `busy` is a terminal sink (no
  `finish`, no resilience) with system `liveness "drains" proven do always(phase ==
  :busy implies eventually(phase == :idle)) end` → `Vor.Explorer.check_file(…,
  max_queue: 3, integer_bound: 2, allow_vacuous: true)` returns `{:ok, :proven, …}`
  while `never(phase == :busy)` is VIOLATED (busy reachable). The single-agent
  compile-time form of the same liveness (declared in the agent) → **refused**.
- **F11 (coverage blind):** `Vor.Simulator.run_file` on `02-jobqueue.vor` with
  `deadline_ms: 50`, `workload_rate: 20`, `inject_faults: false` →
  `stats.coverage.agents.w1.handlers.missing` includes
  `:liveness_timeout_worker_finishes_eventually` while
  `states.phase.reached == [:busy, :idle]` and `accepts.missing == [:finish]`.
- **F14 (inexpressible):** `never(completed > dispatched)` →
  `{:unexpected_in_invariant, …}`; `never(exists Q where Q.completed != Q.dispatched)`
  → VIOLATION at depth 1 (equality is real); `always(job_submitted implies
  eventually(job_done))` → `proven` over undefined identifiers.
- **Mutation 1 (broken recovery stays green):** delete `send :queue {:requeue, …}`
  from the resilience handler, set `deadline_ms: 60`, `Vor.Simulator.run_file` with
  `inject_faults: true`, seeds 1/2/7 → all `{:ok, :pass, …}`.

---

## Next probe

The wall this time was **liveness observability**, not expressiveness: the mechanism
works but no checking or coverage tier can see it (F10, F11, F13). Two candidates:

1. **The agent probe** the briefs have been building toward — hand an agent the job
   queue and watch which of F9–F14 it falls into. The error-quality findings (F9, F12
   raw crashes; F10, F14 silent vacuity) are exactly what will trip an agent, and the
   probe would measure it directly.
2. **A focused fix pass on F10/F11** — they are concrete and squarely on-thesis (a
   green-but-empty liveness proof and a coverage blind spot on the resilience tier),
   analogous to the F3/F4 fixes that came out of Probe 1.
