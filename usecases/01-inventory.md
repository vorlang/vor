# 01 — Inventory / reservation (data-carrying state)

## 1. What it models

A warehouse inventory with a reservation flow. Stock is a quantity that goes up
and down: clients **reserve** units (moving them from *available* to *reserved*),
**release** them back, or **confirm** an order (consuming reserved units). The
interesting state is *how much* — integers that must stay consistent — not *which
mode* an agent is in.

## 2. What it probes

**Hypothesis (stated before the code):** every existing Vor example is pure
coordination — the interesting state is a `role` or a `phase`, and invariants ask
*which state* an agent is in. None have state whose **contents** matter. This
probe asks: **can Vor reason about values?** Specifically the conservation
property `reserved + available == total` and the safety property
`available >= 0`.

**Prediction:** conservation will be *inexpressible* or come back *non-substantive*,
because it reasons about quantities — and the known limitation is that map/
collection contents abstract to `:unknown`, so value-level properties aren't
checkable.

**Prediction verdict: confirmed in outcome, wrong in mechanism.** Modeled with
plain **integers** (not maps), the value invariants are *inexpressible at the tier
that could check them* and *fake-proven at the tier that accepts them*. You hit
the grammar wall and a silent vacuous-proof wall **before** the `:unknown` map
abstraction is ever reached. The most damning result — a `proven` value invariant
that is actually vacuous, with no relevance axis to flag it (F3) — is a new
instance of the exact green-but-empty pattern the rest of the toolchain was built
to catch.

## 3. The program

[`01-inventory.vor`](01-inventory.vor) — an `Inventory(capacity)` agent with
integer `available` / `reserved` / `total`, seeded by `on :init`, driven by
`{:reserve|:release|:confirm, qty}`. Two instances in a `Warehouse` system.

The natural value invariants:

```vor
safety "stock never negative" proven do
  never(available < 0)
end
safety "conservation" proven do
  never(reserved + available != total)
end
```

## 4. What the tiers reported

**Runtime is fine.** `on :init` seeds `available = total = capacity`; a reserve of
2 against capacity 3 yields `available=1, reserved=2, total=3` — conservation
holds at runtime. The problems are entirely in the *checking* tiers.

> **Update (F3/F4 resolved — see the Resolution section).** The table below is
> the *pre-fix* reading that motivated the fixes; the post-fix verdicts are noted
> in each row.

| Invariant | Tier | Strength | Relevance | Notes |
|---|---|---|---|---|
| stock never negative | `mix compile` (gen_server) | ~~"proven"~~ → **refused** | ~~vacuous~~ | Was fake — mutation not caught (F3). **Post-fix:** `:unsupported_invariant`, routed to `monitored`/`mix vor.check`. |
| conservation | `mix compile` (gen_server) | ~~"proven"~~ → **refused** | ~~vacuous~~ | Same — now refused, not fake-proven. |
| *(same, on a gen_statem agent)* | `mix compile` | **refused** | — | `:unsupported_invariant` (F2 — was the honest path; now both paths agree). |
| stock never negative / conservation | `mix vor.check` (system tier) | **inexpressible** | — | Grammar rejects `<`, arithmetic, negative literals (**F1, still open**). Cannot be written in the system block. |
| available reached zero | `mix vor.check` (system tier) | checked | ~~violated at init~~ | Was violated at the initial state (checker started integers at 0, ignored `on :init` — F4). **Post-fix:** init applied, `available = capacity` at the checker's initial state. |

**Mutation test (F3):** replaced the guarded reserve
(`if Q <= available do available - Q`) with an unconditional `available - Q` —
which trivially reaches negative stock. The program **still compiles with
`never(available < 0)` reported "proven."** The planted bug is not caught.

**Simulation:** not usefully reached — with the checker degenerate (F4) and the
value invariants unverifiable, the simulator adds only that the runtime behavior
is correct (already shown above). Coverage/`UNDER-TESTED` not the bottleneck here;
the expressiveness/verification walls are.

## 5. Findings

- **F1 — The value invariants are inexpressible at the tier that could check
  them.** System-level invariants allow only `==`/`!=` per agent (atoms, or a
  non-negative integer for `exists A where A.field == n`) and
  `count(agents where FIELD == atom)`. No inequalities (`< 0`, `>= 0`), no
  arithmetic (`reserved + available == total`), no integer `count`-where. The two
  invariants the domain *is about* cannot be written in the system block.

- **F2 — Agent-level `proven` value invariants behave inconsistently by agent
  kind.** On a **gen_server** agent (no enum state), `never(available < 0)` and
  `never(reserved + available != total)` compile and report "proven." On a
  **gen_statem** agent (an enum `state` present), the *same* invariant is honestly
  **refused** — `:unsupported_invariant`, "change the tier from 'proven' to
  'monitored', or simplify the property." The refuse-behavior exists; it just
  isn't on the gen_server path, which fake-proves instead.

- **F3 — The gen_server "proof" is fake — a new green-but-empty, one tier down.**
  The single-agent safety verifier reasons only over the enum-state graph; a
  gen_server has none, so it passes *any* integer property vacuously. Confirmed by
  mutation (§4). And there is **no relevance axis at the `mix compile` tier**, so
  this vacuous proof is silent — no `substantive`/`vacuous` label, no compile
  error. This is precisely the pattern the checker ("I proved nothing") and
  simulator ("I tested less than I claimed") learned to surface, reappearing at
  the compile tier where nothing yet watches for it. **Most important finding.**
  **RESOLVED** (CHANGELOG / KNOWN_ISSUES §8): `verify_safety` now fails closed — a
  `proven` value/no-graph invariant is refused (`:unsupported_invariant`) with a
  teaching message routing to `mix vor.check` / `monitored`, matching the
  gen_statem path. The mutation is the regression test
  (`test/features/value_verification_test.exs`).

- **F4 — The model checker cannot exercise data-carrying agents that depend on
  non-zero initial quantities.** Integer state defaults to 0 and the explorer
  ignores `on :init`, so the inventory sits at `(0, 0, 0)` in the checker. Every
  guarded handler (`reserve when Q <= available`, i.e. `Q <= 0`) is dead, the
  agent is frozen at the origin, and any system invariant is vacuous or trivially
  decided at the initial state. (Runtime is unaffected — `on :init` fires there.)
  **RESOLVED** (partly): the explorer now applies `on :init` to its initial
  `ProductState`, guarded by a model-vs-reality test (checker initial state ==
  runtime `:sys.get_state`). *Still open:* the explorer does not inject external
  client accepts for a *driverless* agent (no incoming connection), so a
  standalone inventory is still not exercised past init — separate from F4, noted
  as **F8**.

- **F5 — The one expressible value probe is degenerate here.** `vor.check` *does*
  track integers substantively — verified independently: `never(exists A where
  A.available == 3)` on an incrementing counter is **caught** after 0→1→2→3. The
  capability is real; F1 (grammar) and F4 (init gap) are what make it unusable for
  this domain, so `available == 0` violates at the origin rather than exercising
  anything.

- **F6 — Grammar papercuts.** A negative integer literal doesn't parse in an
  invariant RHS (`== -1` → `expected_invariant_rhs :minus`).
  `count(agents where FIELD == <int>)` is rejected — the `count`-`where` value
  must be an atom.

- **F7 — Maps are worse, but you never reach them.** A `map` field can only be
  compared `== <atom>`, which never matches a real map, so any such invariant is
  vacuous; per-key quantities are wholly inexpressible in the invariant language
  and would abstract to `:unknown` regardless. But F1–F4 block the integer value
  invariants first — the `:unknown` abstraction the prediction targeted is not the
  operative wall.

- **F8 — The explorer does not drive a *driverless* agent.** Found while fixing
  F4: with `on :init` now applied (`available = 3`), the standalone `Inventory`
  instance *still* explores only 1 state. The explorer delivers pending messages
  and fires timers, but nothing sends to an agent that has no incoming connection
  and no client, so its guarded handlers never fire and it stays at its initial
  state. This confounds the natural "does a reserve reach `available < capacity`"
  reachability oracle (which is also blocked by F1 — `< capacity` is inexpressible
  at the system tier). To exercise a data-carrying agent in `mix vor.check` you
  must wire a driver agent that sends to it. Separate from F4; open.

## 6. Reproduction

- **Commit:** `0d7db61` (main).
- **Program:** `usecases/01-inventory.vor`.
- **Compile (fake proof):** `Vor.Compiler.compile_string(<Inventory agent>)` →
  `{:ok, …}` with the value invariants "proven"; mutate the reserve to drop the
  `if Q <= available` guard and it still compiles.
- **gen_statem refusal (F2):** add any enum `state phase: :open | :closed`; the
  same invariant → `{:error, %{type: :unsupported_invariant}}`.
- **Check (degenerate):** `Vor.Explorer.check_file("usecases/01-inventory.vor",
  max_depth: 30, max_queue: 3, integer_bound: 3, max_states: 300_000,
  allow_vacuous: true)` → `available reached zero` violated at 1 state.
- **Integer tracking is real (F5):** the same call on an incrementing counter with
  `never(exists A where A.available == 3)` → VIOLATION after 4 states.

---

## Next probe

The wall here was the **invariant grammar** (F1/F6) and the **single-agent
verifier + explorer-init gap** (F3/F4) — *not* the map abstraction the prediction
blamed. Two options, in priority order:

1. **File F3 and F4 as bugs and probe them directly with a minimal
   integer-conservation use-case.** They are concrete and fixable (a silent
   vacuous compile-tier proof; the explorer ignoring `on :init`), and they block
   *all* data-carrying use — more actionable than expanding the invariant grammar.
   F3 in particular is a green-but-empty instance the toolchain currently misses,
   which is squarely the project's thesis.
2. **Pivot the next *use-case* to liveness-dominant coordination** (a job queue:
   "every submitted job eventually completes") — pure coordination that plays to
   Vor's proven strength and exercises the underexercised `monitored`/resilience
   tier, rather than pushing further into the value dead-end this probe mapped.
