# Vor

**A constrained, BEAM-native, AI-assisted declarative language for agent orchestration**

*Relations for knowledge, handlers for effects  ·  The spec is the program*

---

## What is Vor?

Vor is a programming language designed for a world where AI writes software and humans declare intent. Named for the Norse goddess who witnesses oaths, Vor programs are binding declarations: relations that define what is true, invariants that define what must remain true, and protocols that define how agents interact. The AI synthesizes implementations from these declarations. Vor compiles to Erlang/OTP on the BEAM — the same compilation model as Elixir — inheriting battle-tested concurrency, fault tolerance, hot code reloading, and distribution. Erlang, Elixir, and Vor coexist seamlessly in one VM.

## Five Primitives

**Relations** — Bidirectional mappings for knowledge and data transformation. Define a conversion once; query it in any direction. Relations are the declarative core — directional handlers manage effects and stateful behavior.

**Constraints** — Bounds on valid state. Not types — domain properties. Constraints exist at three guarantee tiers: *proven* (compiler-verified, limited to single-agent local properties), *checked* (tested against synthesis output), and *monitored* (enforced at runtime with defined violation responses).

**Protocols** — Typed message interfaces for agents, including ordering, backpressure, and failure semantics. Composition is checked by unifying protocols — type compatibility is necessary but not sufficient; behavioral contracts must also align.

**Invariants** — Temporal properties in the tradition of TLA+. Safety: "this must never happen." Liveness: "this must eventually happen." Each invariant is assigned a guarantee tier — Vor is explicit about what is proven versus what is monitored.

**Synthesis Obligations** — Explicit holes where the AI fills in an implementation. The human provides examples, properties, and performance bounds. If synthesis fails, Vor falls back to the last known good implementation and flags the failure. Erlang/Elixir escape hatches are available for anything synthesis can't handle.

## Boundaries

Vor is a general-purpose BEAM language — suited to anything Erlang and Elixir handle well, including telecom protocol stacks, distributed services, real-time web applications, workflow orchestration, and IoT coordination. Its relational primitives and declarative invariants add particular value where systems involve complex rules, protocol state machines, or correctness requirements that matter.

**What Vor handles:** declarative knowledge (relations), protocol and state machine specification (protocols, invariants), behavioral contracts, and AI-assisted implementation (synthesis).

**What Vor delegates:** performance-critical inner loops, raw system integration, and unconstrained side effects fall to human-authored Erlang/Elixir via escape hatches. Escape hatches are untrusted by default — runtime monitors wrap them and enforce invariants at the boundary.

## When Things Break

**Synthesis failure:** the compiler reports which constraints are unsatisfiable or which obligations the AI couldn't fill. Fallback to last known good implementation or degraded mode.

**Invariant violation:** the supervision tree responds according to the agent's resilience declaration — restart, escalate, or compensate. Violations are observable events, not silent failures.

**Contradictory specs:** the constraint solver detects conflicts at compile time. Underspecification is surfaced as ambiguity warnings.

**Re-synthesis:** preserves behavioral equivalence within constraints, not identical behavior. A new implementation must pass all existing constraints and regression checks before deployment.

## Intellectual Heritage

**Prolog & miniKanren** (relational programming, bidirectional computation) · **Erlang/OTP** (processes, fault tolerance, hot code loading) · **TLA+** (temporal logic, safety/liveness, specification-first design) · **Vericoding** (AI synthesis of verified code from formal specs). Each tradition was limited by the assumption of a human programmer. Vor uses AI as the bridge between specification and execution.

## Design Principles

**The spec is the program.** No separate implementation artifact.

**Relations for knowledge, handlers for effects.** Bidirectional computation where it fits; explicit directionality where effects demand it.

**Guarantee tiers are explicit.** Every property is labeled proven, checked, or monitored. No false confidence.

**Failure is first-class.** Synthesis can fail. Invariants can be violated. Specs can conflict. Vor defines what happens in each case.

**The AI is bounded.** Synthesis operates within declared constraints. Its output is verified before deployment.

---

*vorlang.org  ·  Targets: BEAM/OTP  ·  License: Open Source  ·  Status: Design Phase*
