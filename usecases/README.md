# Vor use-cases

**These are experiments, not documentation.**

The curated `examples/` set shows Vor doing what it was designed to do. This
directory does the opposite: each file is a program written to probe an axis the
examples don't touch — somewhere we genuinely don't know whether Vor can express
the thing — and to **make the language fail in ways we haven't seen yet.**

> Five more variations on "a state machine with an invariant" would confirm what
> we already know. What we want are the programs that don't fit.

**The findings log is the deliverable.** The working program is secondary. Every
place the language got in the way — an invariant that couldn't be written, a
workaround, an abstraction that blocked a check, a proof that turned out vacuous,
an unhelpful error — is the output. Aggregated across use-cases, the findings
become a language roadmap driven by what actually blocked real programs, not by
preference.

## Discipline

- **Hypothesis before code.** State what the use-case probes, up front, so the
  result can *disconfirm* it. A prediction that turns out wrong is the best
  possible outcome — record it clearly.
- **Relevance is mandatory, checked from the first run.** Every reported
  invariant carries **both** axes — strength (`proven`/`checked`/`monitored`)
  **and** relevance (`substantive`/`vacuous`/`unexercised`). A `✓ Proven` without
  a `substantive` beside it is **not** a validation — it is a finding.
- **Mutation-test every "pass."** Deliberately break one invariant and confirm
  the checker *finds* the violation. A checker that can't catch a planted bug is
  exercising nothing, whatever the verdict says.
- **Don't tune the program to flatter the language.** If the natural way to write
  it doesn't work, record that, then write the unnatural way — document both.
- **Don't fix what you find. Log it.** Fixing is a separate decision informed by
  the aggregate across several use-cases.

## Format

One file per use-case: `usecases/NN-name.md`, following `TEMPLATE.md` exactly.
The `.vor` program lives beside it (`usecases/NN-name.vor`), kept clearly
distinct from the curated `examples/`. Findings are numbered (`F1`, `F2`, …) so
they're citable across use-cases.

## Index

- [`01-inventory`](01-inventory.md) — **data-carrying state**: can Vor reason
  about *values* (quantities), not just coordination roles? (Verdict: no tier
  both expresses and substantively checks the natural value invariants.)
