# `docs/` Audit and Triage

> **Resolution (2026-07-23).** The recommendations below were executed in a follow-up:
> the duplicate pairs were resolved (`onepager-current.md`/`comparison-current.md`
> promoted over the falsified originals), every "Raft proven in 1,001 states" figure
> and stale test count was purged, verification wording was softened to the bug-finder
> framing, and the tutorial's runnable code was fixed and **verified end-to-end (18/18
> snippets pass)**. This file is retained as the point-in-time findings record.

**Audit as written — findings and recommendations below (the fixes have since been applied; see the resolution note).**
Baseline: `main` @ `907d65e`. Current suite: **503 tests, 9 property suites** (every doc that cites a test count is stale).

Method: read every file under `docs/`, grepped for the known-falsified claims, and **actually ran** the tutorial's code samples and API calls against the live compiler (`mix run`), plus the README's "Try it" call.

---

## 0. The headline

There are **7** docs, not the 4 the README links. Two of them are **duplicate "-current" rewrites** (`onepager-current.md`, `comparison-current.md`) that are *newer and cleaner* than the versions the README actually links — **the README links the stale originals and the better rewrites sit orphaned.** Consolidating each pair is step one.

The linked `onepager.md` and `comparison.md` are the most falsified docs in the repo — they predate the paper withdrawal and still sell "compile-time multi-agent verification" and "Raft proven in 1,001 states." `developer-guide.md` is current and healthy. `vor-tutorial.md` has **no false verification claims** but its "Try it" snippets call a **compiler API that does not exist** (`Vor.Compiler.compile/1`), so every step's runnable example is broken.

---

## 1. Per-file assessment (Task 1)

| File | Purpose / audience | Last meaningful update | Contradicts README? | Verdict |
|---|---|---|---|---|
| `developer-guide.md` | Internal compiler reference; contributors + coding agent | `907d65e` **2026-07-22** (this session) | No — carries the current caveats | **KEEP** (one-line nit) |
| `vor-tutorial.md` | Learn-by-building rate limiter; new users | `81ac71a` 2026-04-10 | No false *claims*; broken *code* | **UPDATE** (fix API + reply shapes) |
| `onepager.md` *(linked)* | Sales/technical overview | `01b5815` 2026-04-07 | **Yes, heavily** | **DELETE** (superseded by `-current`) |
| `onepager-current.md` *(orphan)* | Sales/technical overview, newer | `81ac71a` 2026-04-10 | Partially (still 1,001 states, 394 tests) | **REWRITE → becomes `onepager.md`** |
| `comparison.md` *(linked)* | "Vor vs the typical stack" | `01b5815` 2026-04-07 | **Yes** | **DELETE** (superseded by `-current`) |
| `comparison-current.md` *(orphan)* | Tool-elimination comparison, newer | `81ac71a` 2026-04-10 | Minor (stale test count, "model checking" framing) | **UPDATE → becomes `comparison.md`** |
| `manifesto.md` *(orphan)* | Vision/philosophy piece | `cfe26ae` 2026-03-29 (initial) | No (explicitly aspirational) | **KEEP** (optionally link) |

---

## 2. Every false claim found, quoted, per file (Task 1 — the important output)

### `docs/onepager.md` — linked, worst offender

- L13: *"The compiler verifies these declarations at compile time. For multi-agent systems, `mix vor.check` model-checks system-level invariants by exploring **all reachable combined states** through **all possible message interleavings**"* — **false**: `mix vor.check` is a bug-finder / bounded checker, not compile-time, and "all reachable states" is intractable beyond small bounds.
- L23: *"Symmetry reduction exploits agent interchangeability (**6× reduction** for three identical Raft nodes)… The Raft 'at most one leader' invariant is **proven exhaustively in 1,001 states**."* — **false on three counts**: symmetry is **unsound** (not orbit-exact); the 1,001-state figure was the **vacuous** result (no leader was reachable); and `never(count(role == :leader) > 1)` is the **mis-specified** invariant (Raft guarantees one leader *per term*).
- L25: uses *"`count(agents where role == :leader) > 1`"* as the sample system invariant — the mis-specified one.
- L41: *"model-checks multi-agent system invariants"* listed under *"Coordination verification (**today**)"* — frames multi-agent checking as delivered verification.
- L56: *"Raft 'at most one leader' proven exhaustively (**1,001 states with symmetry, 8,008 without**)"* — false.
- L68: *"TLA+ specifications verifying the safety verifier"* — **stale**: memory says rerun TLC only after `safety.ex`/`graph.ex` changes; verify the TLA+ specs still correspond (not audited here, flag).
- L69 / L128: *"**349+ tests**"* — stale (503).
- L72: *"verification under 2ms for any graph"* — **false** for multi-agent (`mix vor.check` takes seconds; the honest state space explodes with queue depth).
- L84: *"'at most one leader' proven exhaustively via `mix vor.check` — **1,001 states**"* — false.

### `docs/onepager-current.md` — orphan, newer but still falsified

- L25: *"Uses cone-of-influence abstraction, integer saturation, and **symmetry reduction**. Raft 'at most one leader' **proven in 1,001 states**."* — **false** (symmetry unsound; 1,001 vacuous; mis-specified invariant).
- L27: *"Seed-reproducible."* — **misleading without the caveat**: inputs are seeded, the BEAM scheduler and real timers are not (README states this; this doc omits it).
- L108: *"Raft 'at most one leader' proven in 1,001 states"* — false.
- L110 / L117: *"**394+ tests**"* — stale (503).
- L19/L23: *"Multi-agent model checking… The compiler walks every reachable state and proves…"* — the single-agent line (L23) is fine, but L19's framing of `vor.check` as "model checking" contradicts the README's bug-finder language.

### `docs/comparison.md` — linked

- L13: correctness levels listed as *"proven (compiler-verified single-agent), **model-checked (multi-agent product state exploration)**, monitored"* — frames multi-agent exploration as a verification tier.
- L22: *"Product state exploration via `mix vor.check`. **All message interleavings checked**. State abstraction + symmetry reduction. **Raft proven in 1,001 states**."* — false (interleavings not exhaustive beyond small bounds; symmetry unsound; 1,001 vacuous).
- L26: *"State space explosion for large multi-agent systems (**mitigated by abstraction + symmetry**)"* — symmetry is unsound, not a valid mitigation.
- L28: *"embedded model checker **proving Raft in 1,001 states**… Compilation <5ms, **verification <2ms**"* — false (1,001 vacuous; multi-agent verification is seconds, not <2ms).
- L50: *"The Raft cluster invariant 'at most one leader' is **proven by exploring 1,001 states with symmetry reduction (8,008 without)**."* — false on all three counts.
- L58: *"Vor adds **compile-time verification** of … **multi-agent model checking**."* — false framing.
- L69 (table): *"Distributed coordination bugs | **Yes — model checking**"* — overclaims verification.
- L87: *"the Raft cluster is **proven in 1,001 states**"* — false.
- L28 / L97: *"**349+ tests**"* — stale (503).

### `docs/comparison-current.md` — orphan, cleanest of the three sales docs

- L151: *"**394+ tests**"* — stale (503).
- L15: *"Design verification | … | `mix vor.check` (same source file)"* and L19: *"**Formal verification** + restricted language"* — mild overclaim vs the bug-finder repositioning (single-agent safety *is* formal verification; multi-agent is not). No hard-false figures.
- L114: *"Multi-agent model checking | Not available | `mix vor.check`"* — "model checking" label vs README's "finds counterexamples"; minor.
- L141: *"Bounded verification. The model checker uses integer saturation and queue bounds."* — honest, but silent on symmetry-unsound / POR ~1× (acceptable for a comparison doc).
- **No 1,001-states, no symmetry-multiplier, no mis-specified invariant.** This is why it's UPDATE, not DELETE/REWRITE.

### `docs/vor-tutorial.md` — no false *verification* claims, but broken *runnable code*

Grep for the falsified verification claims returned **zero hits** — the tutorial teaches single-agent state machines and a Producer/Consumer pipeline, never the mis-specified Raft invariant. But running its samples surfaced:

- **`Vor.Compiler.compile/1` does not exist.** Used in steps 1–7 (lines 47, 95, 151, 227, 308, 357, 452, 535). Verified: `Vor.Compiler.compile/1` → `UndefinedFunctionError`. The module exposes `compile_string`, `compile_file`, `compile_and_load`, `compile_system`, `compile_system_and_load`. **Correct call is `Vor.compile/1`** (delegates to `compile_string`) **or `Vor.Compiler.compile_string/1`**. Every step-1-through-7 "Try it" is broken as written.
- **`modules.system.start_link()` is wrong** (step 8, line 609). Verified: `Vor.Compiler.compile_system/1` returns `{:ok, %{system: …, agents: …, system_ir: …}}` where `modules.system` is a **compiled-BEAM map** (`%{binary: <<…>>, …}`), not a module — `modules.system.start_link()` will not work. (The `compile_system/1` call itself succeeds.)
- **Reply-tuple shapes are inconsistent.** Replies carry a map payload — verified: lock `:acquire` → `{:grant, %{client: :alice}}`. The tutorial shows bare `{:sent}` (line 612), `{:denied}` (360), `{:allowed}` (364) for no-field emits, but `{:total, %{value: 30}}` (618) correctly for a fielded one. The no-field cases are almost certainly `{:sent, %{}}` etc. — flag to verify and normalize.
- **Not a claim, but check on rewrite:** step 5's teaching flow (intentionally-failing invariant → `{:error, %{type: :invariant_violation, …}}`, line 309) — confirm the error tuple shape still matches; not verified here.

### `docs/manifesto.md` — vision doc

- No falsifiable technical claims. References AI "synthesis" producing implementations (L15, L23, L25, L27) — a **not-yet-built** capability, but presented explicitly as vision ("*Design phase*", L45), which is legitimate for a manifesto.
- L45 footer *"Design phase"* slightly *understates* reality (there's a working compiler) — an under-claim, harmless.

### `docs/developer-guide.md` — healthy

- No false claims. Header block (L80–87) carries the July-2026 correctness caveats; L100–107 states the bug-finder repositioning, symmetry-unsound, and POR ~1× (with the 20× retraction). Simulation coverage / `UNDER-TESTED` sections current (updated this session).
- **One nit:** L15 labels `mix vor.check` *"multi-agent model checking"* in the three-line summary, which L100 then correctly reframes as "bug-finder, not a compile-time verifier." Harmless given the immediate clarification; align the wording on any pass.

---

## 3. Triage verdicts + rationale (Task 2)

- **`onepager.md` → DELETE.** Its premise (compile-time multi-agent verification, "proven in 1,001 states") is the falsified core, and a strictly-better, newer rewrite already exists (`onepager-current.md`). Deleting the stale one and promoting the rewrite is cleaner than half-correcting two parallel docs.
- **`onepager-current.md` → REWRITE, then rename to `onepager.md`.** Newer and better-structured (three-tier, chaos, telemetry, sensitive fields all accurate), but still repeats "Raft proven in 1,001 states" (×3), "394+ tests," bare "seed-reproducible," and symmetry-as-mitigation. Fixable — it needs the Raft/symmetry/test-count/seed claims brought in line with the rewritten README, not a from-scratch rebuild.
- **`comparison.md` → DELETE.** Premise partly rests on the falsified framing, and `comparison-current.md` is a cleaner take on the same "vs the stack" idea. *Note:* the README's *description* ("how Vor compares to the typical stack") actually matches `comparison-current.md` **better** than the doc it links.
- **`comparison-current.md` → UPDATE, then rename to `comparison.md`.** Only real fixes: bump "394+ tests," and soften "design verification"/"formal verification"/"model checking" to match the bug-finder framing. No falsified figures to purge. This is the lightest-touch of the sales docs.
- **`developer-guide.md` → KEEP.** Current. Optional one-line wording alignment at L15.
- **`vor-tutorial.md` → UPDATE (code, not claims).** Replace `Vor.Compiler.compile(...)` → `Vor.compile(...)` throughout; fix the step-8 system start-up call; normalize reply-tuple shapes; re-verify the step-5 error tuple. This is a mechanical correctness pass — the pedagogy is sound.
- **`manifesto.md` → KEEP.** Vision piece, no false claims; decide separately whether to link it from the README.

**Deletion vs half-correction:** the brief's "prefer deletion where the premise no longer holds" applies cleanly to the two linked `*.md` originals — but only because a corrected sibling already exists. Net doc count stays the same (delete 2 stale, promote 2 rewrites).

---

## 4. README Background-link check (Task 3)

README (lines 287–290) links four docs. **All four link targets exist (no 404s).** But:

| README link | Description given | Reality |
|---|---|---|
| `docs/onepager.md` | "technical overview" | **Links the most-falsified doc.** A newer clean-er rewrite (`onepager-current.md`) exists but isn't linked. |
| `docs/comparison.md` | "how Vor compares to the typical stack" | Links the stale version; **`comparison-current.md` fits this description better** and isn't linked. |
| `docs/developer-guide.md` | "internal compiler reference" | ✅ Accurate and current. |
| `docs/vor-tutorial.md` | "step-by-step from Echo agent to multi-agent pipeline" | ✅ Description accurate; but the code samples don't run (§2). |

The README itself is honest (rewritten). The damage is that it **routes readers to the two docs that contradict it.** After the delete/rename in §3, the links keep pointing at `onepager.md` / `comparison.md` and automatically resolve to the corrected content — no README edit needed beyond confirming.

---

## 5. Orphaned docs (Task 4)

Not linked from README, `docs/`-internal indexes, or (spot-checked) elsewhere:

- **`docs/onepager-current.md`** — newer than the linked `onepager.md`; orphaned. The "-current" naming suggests an in-progress swap that never completed.
- **`docs/comparison-current.md`** — newer than the linked `comparison.md`; orphaned. Same story.
- **`docs/manifesto.md`** — vision piece, never linked. Harmless but forgotten; candidate to link from README Background or leave as-is.

The `*-current.md` pattern is the real smell: two half-finished doc migrations left both versions in the tree, and the README kept pointing at the old halves.

(Note: `KNOWN_ISSUES.md` and `evidence/` are out of scope per the brief — left untouched, intentionally in the archaeological register.)

---

## 6. Recommended order of work (for the follow-up brief)

1. **Resolve the duplicate pairs first — highest leverage, removes the worst falsehoods.**
   a. `onepager-current.md`: purge the 1,001-states / symmetry / 394-tests / bare-"seed-reproducible" claims → `git mv` over `onepager.md` (delete the old).
   b. `comparison-current.md`: bump test count, soften "verification"/"model-checking" wording → `git mv` over `comparison.md`.
   Result: both README links now resolve to honest content; four stale/duplicate files collapse to two correct ones.
2. **Tutorial correctness pass** (mechanical, no premise change): `Vor.Compiler.compile` → `Vor.compile`; fix step-8 system startup; normalize reply tuples; re-verify step-5 error shape. Then re-run every snippet end-to-end (the samples are short and self-contained).
3. **Developer-guide one-liner**: align L15 wording with the bug-finder framing (optional).
4. **Decide manifesto**: link from README Background or leave orphaned (no content change needed).
5. **Cross-check any surviving test-count / timing figures** against `mix test` at the time of the follow-up (they drift every phase — consider dropping hard counts from prose in favor of "the suite" to stop the bleeding).

**Single most important fix:** kill the "Raft proven in 1,001 states" sentence wherever it appears (`onepager.md` ×3, `onepager-current.md` ×3, `comparison.md` ×3) — it is the exact claim the paper withdrawal was about, and it currently greets every reader who clicks "One-pager" from the README.
