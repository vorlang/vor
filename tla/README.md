# TLA+ Specifications for Vor's Compiler

These specifications formally define the correctness properties of Vor's
safety verifier and state graph extraction. TLC model checking exhaustively
verifies these properties for all possible inputs within bounded size.

**Last verified: 2026-04-02** — Both specs pass TLC with no errors found.
- VorSafetyVerifier: 15,934,464 distinct states, 0 violations
- VorGraphExtraction: 903 distinct states, 0 violations

## What these prove

**VorSafetyVerifier.tla** — For every possible state graph (up to 3 states,
3 message tags) and every possible safety invariant:
- If the verifier says "proven", the property actually holds (soundness)
- If the verifier says "violated", the property is actually violated (completeness)
- Unrecognized invariant bodies are never accepted as proven (fail-closed)

**VorGraphExtraction.tla** — For every possible set of handlers (up to 4)
with mixed state-field and non-state-field guards:
- The extracted graph contains exactly the declared states (no phantoms)
- Transitions are correct for the state field guards
- Non-state-field guards do not affect the graph
- Emit maps correctly reflect what each state can emit

## Prerequisites

Install the TLA+ tools:
- Download from https://github.com/tlaplus/tlaplus/releases
- Or use the VS Code TLA+ extension

## Running

```bash
# Verify the safety verifier
cd tla
tlc VorSafetyVerifier.tla -config VorSafetyVerifier.cfg

# Verify the graph extraction
tlc VorGraphExtraction.tla -config VorGraphExtraction.cfg
```

Both should complete with "Model checking completed. No error has been found."

## Relationship to the Elixir implementation

These specs define the *contract* that the Elixir implementation must satisfy.
The specs are the reference; the Elixir code is the implementation. If the
Elixir code changes, check it against these specs by reviewing whether the
algorithm still matches the TLA+ model.

The specs do NOT automatically test the Elixir code. They verify the
*algorithm* is correct. Ensuring the Elixir code faithfully implements
the algorithm is a manual review step.

## Bounds and coverage

TLC checks every state within the configured bounds:
- VorSafetyVerifier: 3 states x 3 message tags = ~16M distinct states (~2 min)
- VorGraphExtraction: 2 states x 1 other field x 1 other atom x up to 2 handlers = 903 distinct states (<1s)

Increasing bounds increases coverage but also checking time exponentially.
The VorSafetyVerifier bounds are near the practical limit for exhaustive
checking. The VorGraphExtraction bounds can be increased by editing the
`.cfg` file — add more DeclaredStates, OtherFieldNames, or OtherAtoms.

## Running TLC locally

Download `tla2tools.jar` from https://github.com/tlaplus/tlaplus/releases
and place it in the `tla/` directory (it's gitignored), then:

```bash
cd tla
java -XX:+UseParallelGC -jar tla2tools.jar -config VorSafetyVerifier.cfg VorSafetyVerifier.tla
java -XX:+UseParallelGC -jar tla2tools.jar -config VorGraphExtraction.cfg VorGraphExtraction.tla
```
