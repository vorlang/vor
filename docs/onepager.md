# Vor

**A BEAM-native language with relations, protocols, and verifiable invariants**

*Relations for knowledge, handlers for effects  ·  The spec is the program*

---

## What is Vor?

Vor is a programming language that compiles to Erlang/OTP on the BEAM — the same compilation model as Elixir. At runtime, a Vor agent is indistinguishable from a hand-written gen_server or gen_statem. Erlang, Elixir, Gleam, and Vor coexist seamlessly in one VM.

What Vor adds is a verification layer that OTP doesn't provide. You declare state machines with enumerated states, message protocols with typed interfaces, and invariants as temporal logic properties. The compiler verifies these declarations at compile time. For multi-agent systems, `mix vor.check` model-checks system-level invariants by exploring all reachable combined states through all possible message interleavings — with state abstraction, integer bounding, and symmetry reduction to keep exploration tractable. Named for the Norse goddess who witnesses oaths, Vor programs are binding declarations that the compiler enforces.

## Core Primitives

**State Declarations** — Explicit enumeration of valid states. When present, the agent compiles to a gen_statem. The compiler has the complete state graph and can verify transitions against safety invariants. Non-enum state fields (integers, atoms, maps, lists) are stored in the gen_statem data map or the gen_server state map, with type-appropriate defaults.

**Protocols** — Typed message interfaces for agents. `accepts` declares what an agent receives. `emits` declares synchronous replies. `sends` declares messages forwarded to other agents. Protocol composition is checked at compile time when agents are wired together in a system block — tag mismatches and field name mismatches are compile errors.

**Invariants** — Temporal properties in the tradition of TLA+. Safety invariants ("this must never happen") are tagged `proven` and verified at compile time by exhaustive graph traversal. Liveness invariants ("this must eventually happen") are tagged `monitored` and enforced at runtime via gen_statem state timeouts. The compiler rejects `proven` invariants it cannot verify — it fails closed, never silently accepting unverifiable properties. Proven invariants cannot depend on extern results.

**Multi-Agent Model Checking** — System-level safety invariants are verified by product state exploration via `mix vor.check`. The explorer constructs all reachable combined states, systematically delivers messages in every possible order, and checks invariants at every reachable state. State abstraction tracks only invariant-relevant fields. Integer saturation bounds unbounded fields. Symmetry reduction exploits agent interchangeability (6× reduction for three identical Raft nodes). Counterexample traces show the exact message interleaving that causes a violation. The Raft "at most one leader" invariant is proven exhaustively in 1,001 states.

**System-Level Invariant Language** — Count-based (`count(agents where role == :leader) > 1`), existential (`exists A, B where A.phase == :held and B.phase == :held`), universal (`for_all agents, mode == :idle or mode == :active`), cross-agent comparison (`A.current_term != B.current_term`), and named agent references (`n1.role == :leader`).

**Resilience** — Declarative failure handling. What happens when a liveness invariant is violated, when a process is stuck, when recovery is needed. Resilience handlers are generated as regular handler clauses and included in the state graph — the safety verifier checks them too, ensuring the recovery path doesn't introduce new bugs.

**Relations** — Bidirectional mappings for knowledge and data transformation. Define a relation once; query it in any direction. Fact-based relations support multi-directional lookup. Equation-based relations are automatically inverted at compile time — define `F = C * 9/5 + 32`, query with either variable. The solver handles the directionality.

**Multi-Agent Systems** — Agents are wired together in `system` blocks with named instances, parameters, and connection topology. The compiler generates an OTP Supervisor and Registry. `send` delivers messages to specific named agents. `broadcast` delivers to all connected agents. Agents discover each other via the Registry and automatically re-register on restart.

**Init Handlers** — `on :init` runs once during agent startup, before accepting messages. Supports extern calls for loading persisted state, parameter-based initialization, and setup logic.

**Extern Declarations** — Escape hatches to Erlang, Elixir, and Gleam for anything Vor doesn't handle natively. Extern calls are untrusted by default — wrapped in try/catch. A `proven` invariant whose verification path depends on an extern result is rejected at compile time, consistent with fail-closed philosophy.

**Gleam Extern Support** — First-class interop with Gleam modules via `extern gleam` blocks. Gleam's slash-separated module paths compile directly to BEAM module calls. When Gleam's `package-interface.json` is available, the Vor compiler validates extern declarations against Gleam's actual type signatures at compile time.

## Type Safety Strategy

**Coordination verification (today).** The compiler proves state machine properties, checks protocol compatibility, verifies handler coverage, and model-checks multi-agent system invariants.

**Gleam boundary validation (today).** Extern declarations are validated against Gleam's type metadata.

**Internal type tracking (today).** The compiler propagates types through handler body expressions. Guaranteed crashes (map operations on integers, arithmetic on maps) are caught at compile time. Gleam extern return types flow through the handler body.

**Long-term direction.** E-graph-based equality saturation for verifying CRDT merge properties. Multi-agent liveness checking in the product graph.

## What's Working

The compiler is real and tested:

- Full pipeline: `.vor` source → Lexer → Parser → AST → IR → Verification → Erlang codegen → BEAM binary
- Compile-time safety verification via state graph traversal
- Multi-agent model checking via product state exploration with state abstraction, integer bounding, queue bounding, and symmetry reduction
- Raft "at most one leader" proven exhaustively (1,001 states with symmetry, 8,008 without)
- System-level invariants: count, exists, for_all, cross-agent comparison, named agent references
- Runtime liveness monitoring via gen_statem state timeouts
- Internal type tracking through handler body expressions
- Bidirectional relation solver with compile-time equation inversion
- Protocol composition checking across multi-agent systems
- Registry-based inter-agent messaging with `send` and `broadcast`
- Gleam extern support with compile-time type boundary validation
- Extern proven boundary enforcement (compile error, not warning)
- Init handlers for persistent agent startup
- Native map operations (get, put, merge, has, delete, size, sum) with LWW and max merge strategies
- Native list operations (head, tail, append, prepend, length, empty)
- TLA+ specifications verifying the safety verifier and graph extraction algorithms
- 349+ tests, 9 property-based test suites
- Five working examples with verified invariants and multi-agent coordination
- CRDT examples verified native: G-Counter, PN-Counter, version-based OR-Set — zero extern calls
- Compilation under 5ms for any agent, verification under 2ms for any graph

## Examples

**Distributed lock** — gen_statem with FIFO wait queue. Proven safety invariant: "never grant the lock while it's held." Liveness timeout with automatic release via resilience handler. Verification is total: every property is proven, no extern dependencies in the verification path.

**Circuit breaker** — gen_statem with three states (closed/open/half_open). Proven safety invariant: "no forwarding when open." Liveness monitoring for recovery timeout.

**G-Counter CRDT** — fully native (zero externs), periodic gossip via `every`, cluster convergence verified. Demonstrates CRDT merge with `map_merge(:max)`.

**Rate limiter** — gen_server with extern calls to ETS, parameterized limits, per-client tracking. Demonstrates the Vor-Elixir boundary.

**Raft consensus** — three-node cluster with leader election, conditional vote granting, and leader promotion on majority. System-level invariant "at most one leader" proven exhaustively via `mix vor.check` — 1,001 states with symmetry reduction, all message interleavings checked.

## Boundaries

**What Vor verifies:** single-agent state machine properties (proven at compile time), multi-agent system properties (via product state exploration), handler coverage, protocol composition, liveness with declared recovery, type correctness through handler bodies.

**What Vor monitors:** liveness invariants at runtime, with automatic recovery. Violations are observable events.

**What Vor delegates:** complex data transformation, database access, HTTP, string processing. These fall to Gleam (type-safe, validated at the boundary) or Elixir/Erlang (via extern declarations).

## When Things Break

**Safety invariant violated at compile time:** compilation fails with a clear error.

**System-level invariant violation found by model checker:** `mix vor.check` reports the exact counterexample trace.

**Proven invariant depends on extern:** compilation fails.

**Type error in handler body:** guaranteed crashes caught at compile time.

**Liveness invariant violated at runtime:** resilience handler fires.

**Protocol mismatch:** compilation fails.

## Intellectual Heritage

**Erlang/OTP** (processes, fault tolerance — runtime foundation) · **TLA+** (temporal logic, safety/liveness — verification foundation, also verifies Vor's own verifier) · **Stateright** (embedded model checking on executable code — inspiration for multi-agent verification) · **Prolog & miniKanren** (relational programming) · **Alloy** (first-order relational logic).

## Design Principles

**The spec is the program.** No separate implementation artifact. No drift.

**Guarantee tiers are explicit.** Every property is labeled proven or monitored. The compiler fails closed.

**The extern boundary is a trust boundary.** Proven invariants cannot depend on extern results. Gleam externs are type-validated.

**Failure is first-class.** Invariants can be violated. Resilience handlers define recovery. Recovery paths are verified.

**The BEAM is the foundation.** Vor compiles to OTP and adds verification above it.

**Clean language boundaries.** Vor for verified coordination. Gleam for type-safe data processing. Elixir for OTP infrastructure.

---

*vorlang.org  ·  Targets: BEAM/OTP  ·  License: MIT  ·  Status: Working compiler, 349+ tests, Raft proven in 1,001 states*
