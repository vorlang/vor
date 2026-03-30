# Vor

**A BEAM-native language with relations, protocols, and verifiable invariants**

*Relations for knowledge, handlers for effects  ·  The spec is the program*

---

## What is Vor?

Vor is a programming language that compiles to Erlang/OTP on the BEAM — the same compilation model as Elixir. At runtime, a Vor agent is indistinguishable from a hand-written gen_server or gen_statem. Erlang, Elixir, and Vor coexist seamlessly in one VM.

What Vor adds is a verification layer that OTP doesn't provide. You declare state machines with enumerated states, message protocols with typed interfaces, and invariants as temporal logic properties. The compiler verifies these declarations — checking that state transitions are valid, that protocols are compatible, and that safety properties hold — before producing BEAM bytecode. Named for the Norse goddess who witnesses oaths, Vor programs are binding declarations that the compiler enforces.

## Core Primitives

**Relations** — Bidirectional mappings for knowledge and data transformation. Define a conversion once; query it in any direction. Relations are the declarative core — directional handlers manage effects and stateful behavior.

**State Declarations** — Explicit enumeration of valid states. When present, the agent compiles to a gen_statem. The compiler has the complete state graph and can verify transitions against safety invariants.

**Protocols** — Typed message interfaces for agents, including ordering, backpressure, and failure semantics. Composition is checked by unifying protocols — type compatibility is necessary but not sufficient; behavioral contracts must also align.

**Invariants** — Temporal properties in the tradition of TLA+. Safety: "this must never happen." Liveness: "this must eventually happen." Each invariant is assigned a guarantee tier: *proven* (compiler-verified, limited to single-agent local properties), *checked* (tested against output), or *monitored* (enforced at runtime with defined violation responses).

**Resilience** — Declarative failure handling. What happens when an invariant is violated, when a process crashes, when a constraint can't be satisfied. Maps to OTP supervision strategies but derived from the spec rather than hand-configured.

## Future: AI-Assisted Synthesis

Vor's declarative structure is designed so that AI can eventually fill in implementation details within declared constraints. Synthesis obligations — explicit holes where the human provides properties and bounds and AI provides an implementation — are part of the language design but not yet implemented. The verification story works today without AI. AI synthesis is an accelerator, not a prerequisite.

## Boundaries

Vor is a general-purpose BEAM language — suited to anything Erlang and Elixir handle well, including telecom protocol stacks, distributed services, real-time web applications, workflow orchestration, and IoT coordination. Its relational primitives and declarative invariants add particular value where systems involve complex rules, protocol state machines, or correctness requirements that matter.

**What Vor handles:** declarative knowledge (relations), protocol and state machine specification (protocols, invariants), behavioral contracts, and AI-assisted implementation (synthesis).

**What Vor delegates:** performance-critical inner loops, raw system integration, and unconstrained side effects fall to human-authored Erlang/Elixir via escape hatches. Escape hatches are untrusted by default — runtime monitors wrap them and enforce invariants at the boundary.

## When Things Break

**Invariant violation at runtime:** the supervision tree responds according to the agent's resilience declaration — restart, escalate, or compensate. Violations are observable events, not silent failures.

**Contradictory specs:** the constraint solver detects conflicts at compile time. Underspecification is surfaced as ambiguity warnings.

**Escape hatch violations:** Erlang/Elixir code called from Vor agents is untrusted by default. Runtime monitors enforce invariants at the boundary.

## Intellectual Heritage

**Erlang/OTP** (processes, fault tolerance, hot code loading — Vor's runtime foundation) · **TLA+** (temporal logic, safety/liveness, specification-first design) · **Prolog & miniKanren** (relational programming, bidirectional computation) · **Vericoding** (AI synthesis of verified code from formal specs — an emerging approach that Vor is designed to leverage as it matures).

## Design Principles

**The spec is the program.** No separate implementation artifact. No drift.

**Relations for knowledge, handlers for effects.** Bidirectional computation where it fits; explicit directionality where effects demand it.

**Guarantee tiers are explicit.** Every property is labeled proven, checked, or monitored. No false confidence.

**Failure is first-class.** Invariants can be violated. Specs can conflict. Vor defines what happens in each case.

**The BEAM is the foundation.** Vor doesn't replace OTP — it compiles to OTP and adds verification above it.

---

*vorlang.org  ·  Targets: BEAM/OTP  ·  License: Open Source  ·  Status: Early stage, working compiler*
