# NN — <name>

## 1. What it models

One paragraph, plainly. A reader should understand the domain without knowing
Vor.

## 2. What it probes

**The hypothesis — written BEFORE the code.** The experimental purpose, stated so
the result can disconfirm it. What axis does this touch that the `examples/`
don't? Where do we genuinely not know if Vor can express the thing?

## 3. The program

Link to the `.vor` file; key excerpts inline (not the whole thing).

## 4. What the tiers reported

`mix compile` / `mix vor.check` / `mix vor.simulate` results.

> **MANDATORY: every invariant is reported with BOTH axes — strength AND
> relevance.** A `✓ Proven` without a `substantive` beside it does not count as
> validated; a vacuous or unexercised result is a finding, not a pass.

| Invariant | Tier | Strength | Relevance | Notes |
|---|---|---|---|---|

Also record simulation coverage (declared-vs-observed) and whether any run came
back `UNDER-TESTED`. Record the **mutation test**: which invariant was broken and
whether the checker caught it.

## 5. Findings

**The real deliverable.** Numbered (`F1`, `F2`, …). One entry for every: thing
the language couldn't express; workaround invented; abstraction that blocked a
check; confusing/unhelpful error; invariant that came back vacuous/unexercised
and why; surprise, awkwardness, or friction. Be blunt — findings that make Vor
look bad are the valuable ones.

## 6. Reproduction

Commit SHA, exact commands, full config (bounds, seeds).
