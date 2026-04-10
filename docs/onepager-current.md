# Vor

**A BEAM-native language with relations, protocols, and verifiable invariants**

*Relations for knowledge, handlers for effects  ·  The spec is the program*

---

## What is Vor?

Vor is a programming language that compiles to Erlang/OTP on the BEAM. At runtime, a Vor agent is indistinguishable from a hand-written gen_server or gen_statem. Gleam and Vor coexist seamlessly on one VM — Vor for verified coordination, Gleam for type-safe data processing when needed.

What Vor adds is a verification layer that OTP doesn't provide. You declare state machines with enumerated states, message protocols with typed interfaces, and invariants as temporal logic properties. The compiler verifies these declarations at compile time. For multi-agent systems, `mix vor.check` model-checks system-level invariants by exploring all reachable combined states through all possible message interleavings. Named for the Norse goddess who witnesses oaths, Vor programs are binding declarations that the compiler enforces.

All five examples ship fully native — zero externs. The Raft consensus implementation is proven safe (leader uniqueness) in 1,001 states by the embedded model checker.

## Core Primitives

**State Declarations** — Explicit enumeration of valid states. When present, the agent compiles to a gen_statem. The compiler has the complete state graph and can verify transitions against safety invariants.

**Protocols** — Typed message interfaces for agents. `accepts`, `emits`, `sends`. Protocol composition is checked at compile time when agents are wired together — tag mismatches and field name mismatches are compile errors.

**Invariants** — Temporal properties in the tradition of TLA+. Safety invariants are tagged `proven` and verified at compile time. Liveness invariants are tagged `monitored` and enforced at runtime. The compiler fails closed — never silently accepting unverifiable properties. Proven invariants cannot depend on extern results.

**Multi-Agent Model Checking** — System-level safety invariants verified by product state exploration via `mix vor.check`. Cone-of-influence abstraction tracks only invariant-relevant fields. Integer saturation bounds numeric dimensions. Symmetry reduction exploits agent interchangeability. Counterexample traces show the exact message interleaving that causes a violation.

**System-Level Invariant Language** — Count-based (`count(agents where role == :leader) > 1`), existential (`exists A, B where ...`), universal (`for_all agents, ...`), cross-agent comparison (`A.current_term != B.current_term`), and named agent references.

**Resilience** — Declarative failure handling. Recovery handlers are verified against safety invariants.

**Relations** — Bidirectional mappings for knowledge and data transformation. Equation-based relations are automatically inverted at compile time.

**Multi-Agent Systems** — Agents wired in `system` blocks with named instances and connection topology. `send` for directed, `broadcast` for fan-out. Registry-based discovery.

**Extern Declarations** — Escape hatches to Gleam (type-validated boundary), Erlang, and Elixir when needed. All five examples are fully native without externs.

## Type Safety Strategy

**Coordination verification (today).** State machine properties, protocol compatibility, handler coverage, multi-agent model checking.

**Gleam boundary validation (today).** Extern declarations validated against Gleam's type metadata.

**Internal type tracking (today).** Types propagated through handler bodies. Guaranteed crashes caught at compile time.

## What's Working

- Full compiler pipeline to BEAM bytecode
- Compile-time safety verification via state graph traversal
- Multi-agent model checking with cone-of-influence, integer saturation, symmetry reduction
- Raft "at most one leader" proven in 1,001 states
- System-level invariants: count, exists, for_all, cross-agent comparisons, named refs
- Runtime liveness monitoring with declared recovery
- Internal type tracking through handler bodies
- Protocol composition checking
- Gleam extern support with type boundary validation
- Extern proven boundary enforcement
- Native map operations (get, put, merge, has, delete, size, sum) with merge strategies
- Native list operations (head, tail, append, prepend, length, empty)
- Bidirectional relations, init handlers, periodic timers
- TLA+ specifications verifying the safety verifier
- 351+ tests, 9 property-based test suites
- All five examples fully native — zero externs
- Three CRDT types verified native: G-Counter, PN-Counter, OR-Set

## Examples

All examples are fully native — zero extern calls. Every decision path is visible to the compiler and model checker.

**Distributed lock** — FIFO wait queue with native list ops. Proven: "never grant when held." Liveness timeout with auto-release.

**Circuit breaker** — Three states (closed/open/half_open). Proven: "no forwarding when open." Liveness recovery.

**Raft consensus** — Three-node cluster with native arithmetic and list ops. Model-checked: "at most one leader" proven in 1,001 states via `mix vor.check`.

**G-Counter CRDT** — Native map ops, periodic gossip via `every`. Merge with `map_merge(:max)`.

**Rate limiter** — Native map ops for per-client request counting. Demonstrates stateful request tracking without external storage.

## Boundaries

**What Vor verifies:** single-agent state machine properties, multi-agent system properties, handler coverage, protocol composition, liveness with recovery, type correctness through handler bodies.

**What Vor delegates:** complex data transformation stays in Gleam when needed, called through the type-validated extern boundary. All five examples demonstrate that common coordination patterns — locks, circuit breakers, consensus, CRDTs, rate limiting — are expressible natively.

## Design Principles

**The spec is the program.** No separate implementation artifact. No drift.

**Guarantee tiers are explicit.** The compiler fails closed.

**The extern boundary is a trust boundary.** Proven invariants cannot depend on extern results. Gleam externs are type-validated.

**Failure is first-class.** Recovery paths are verified.

**The BEAM is the foundation.** Vor compiles to OTP and adds verification above it.

---

*vorlang.org  ·  Targets: BEAM/OTP  ·  License: MIT  ·  Status: 351+ tests, all examples native, Raft proven in 1,001 states*
