# Vor

**A BEAM-native language with relations, protocols, and verifiable invariants**

*Relations for knowledge, handlers for effects  ·  The spec is the program*

---

## What is Vor?

Vor is a programming language that compiles to Erlang/OTP on the BEAM — the same compilation model as Elixir. At runtime, a Vor agent is indistinguishable from a hand-written gen_server or gen_statem. Erlang, Elixir, Gleam, and Vor coexist seamlessly in one VM.

What Vor adds is a verification layer that OTP doesn't provide. You declare state machines with enumerated states, message protocols with typed interfaces, and invariants as temporal logic properties. The compiler verifies these declarations — checking that state transitions are valid, that protocols are compatible, and that safety properties hold — before producing BEAM bytecode. Named for the Norse goddess who witnesses oaths, Vor programs are binding declarations that the compiler enforces.

## Core Primitives

**Relations** — Bidirectional mappings for knowledge and data transformation. Define a relation once; query it in any direction. Fact-based relations support multi-directional lookup. Equation-based relations are automatically inverted at compile time — define `F = C * 9/5 + 32`, query with either variable. The solver handles the directionality.

**State Declarations** — Explicit enumeration of valid states. When present, the agent compiles to a gen_statem. The compiler has the complete state graph and can verify transitions against safety invariants. Non-enum state fields (integers, atoms, maps, lists) are stored in the gen_statem data map or the gen_server state map, with type-appropriate defaults.

**Protocols** — Typed message interfaces for agents. `accepts` declares what an agent receives. `emits` declares synchronous replies. `sends` declares messages forwarded to other agents. Protocol composition is checked at compile time when agents are wired together in a system block — tag mismatches and field name mismatches are compile errors.

**Invariants** — Temporal properties in the tradition of TLA+. Safety invariants ("this must never happen") are tagged `proven` and verified at compile time by exhaustive graph traversal. Liveness invariants ("this must eventually happen") are tagged `monitored` and enforced at runtime via gen_statem state timeouts. The compiler rejects `proven` invariants it cannot verify — it fails closed, never silently accepting unverifiable properties.

**Resilience** — Declarative failure handling. What happens when a liveness invariant is violated, when a process is stuck, when recovery is needed. Resilience handlers are generated as regular handler clauses and included in the state graph — the safety verifier checks them too, ensuring the recovery path doesn't introduce new bugs.

**Multi-Agent Systems** — Agents are wired together in `system` blocks with named instances, parameters, and connection topology. The compiler generates an OTP Supervisor and Registry. `send` delivers messages to specific named agents. `broadcast` delivers to all connected agents. Agents discover each other via the Registry and automatically re-register on restart.

**Init Handlers** — `on :init` runs once during agent startup, before accepting messages. Supports extern calls for loading persisted state, parameter-based initialization, and setup logic. No race window between agent start and initial state.

**Extern Declarations** — Escape hatches to Erlang, Elixir, and Gleam for anything Vor doesn't handle natively: data processing, database access, HTTP calls, string manipulation. Extern calls are untrusted by default — wrapped in try/catch, and the compiler warns if a `proven` invariant depends on an extern result.

**Gleam Extern Support** — First-class interop with Gleam modules via `extern gleam` blocks. Gleam's slash-separated module paths (`vordb/counter.increment()`) compile directly to BEAM module calls (`'vordb@counter':increment()`). When Gleam's `package-interface.json` is available, the Vor compiler validates extern declarations against Gleam's actual type signatures — catching arity mismatches, parameter type mismatches, and return type mismatches at compile time. This creates a type-checked boundary between Vor's verified coordination layer and Gleam's type-safe data processing layer.

## Type Safety Strategy

Vor's approach to type safety is layered and complementary to the BEAM ecosystem:

**Coordination verification (today).** The compiler proves state machine properties, checks protocol compatibility, and verifies handler coverage. This catches the bugs that type systems can't — illegal state transitions, missing message handlers, stuck processes.

**Gleam boundary validation (today).** Extern declarations are validated against Gleam's type metadata. The extern boundary — where Vor's verified coordination meets Gleam's typed data processing — is type-checked in both directions.

**Internal type tracking (in progress).** The compiler propagates types through handler body expressions, using declared state field types and built-in operation signatures. Guaranteed crashes (map operations on integers, arithmetic on maps) are caught at compile time. Gleam extern return types flow through the handler body, extending type coverage beyond the extern boundary.

**Long-term direction.** E-graph-based equality saturation for verifying CRDT merge properties (commutativity, associativity, idempotency). User-defined CRDT merge functions with compiler-verified algebraic properties. Multi-agent runtime monitoring for system-level invariants.

## What's Working

The compiler is real and tested:

- Full pipeline: `.vor` source → Lexer → Parser → AST → IR → Verification → Erlang codegen → BEAM binary
- Compile-time safety verification via state graph traversal
- Runtime liveness monitoring via gen_statem state timeouts
- Bidirectional relation solver with compile-time equation inversion
- Protocol composition checking across multi-agent systems
- Registry-based inter-agent messaging with `send` and `broadcast`
- Gleam extern support with compile-time type boundary validation
- Init handlers for persistent agent startup
- Native map operations (get, put, merge, has, delete, size, sum) with LWW and max merge strategies
- Native list operations (head, tail, append, prepend, length, empty)
- TLA+ specifications verifying the safety verifier and graph extraction algorithms
- 287+ tests, 9 property-based test suites, adversarial edge case testing, performance benchmarks
- Five working examples: rate limiter, circuit breaker, Raft consensus, G-Counter CRDT, distributed lock
- CRDT examples verified native: G-Counter, PN-Counter, version-based OR-Set — zero extern calls
- Compilation under 5ms for any agent, verification under 2ms for any graph

## Examples

**Rate limiter** — gen_server with extern calls to ETS, parameterized limits, per-client tracking.

**Circuit breaker** — gen_statem with three states (closed/open/half_open), proven safety invariant ("no forwarding when open"), liveness monitoring for recovery timeout.

**Raft consensus** — three-node cluster with leader election via liveness-triggered candidacy, conditional vote granting, leader promotion on majority, and verified safety invariants. All node-to-node communication via native `send` and `broadcast`.

**G-Counter CRDT** — fully native (zero externs), periodic gossip via `every`, cluster convergence verified. Demonstrates CRDT merge with `map_merge(:max)`.

**Distributed lock** — FIFO wait queue with `list_append`/`list_head`/`list_tail`, proven safety invariant ("no grant when held"), liveness timeout with automatic release via resilience handler.

## Boundaries

Vor is suited to anything involving state machines, message protocols, or correctness requirements: telecom protocol stacks, distributed consensus, CRDT-based data stores, payment processing, workflow orchestration, IoT coordination. Its primitives add particular value where getting the state machine wrong has real consequences.

**What Vor handles:** state machine specification, message protocol verification, safety and liveness invariants, multi-agent coordination, CRDT merge logic, declarative knowledge via relations.

**What Vor delegates:** complex data transformation, database access, HTTP, string processing, and anything that's data processing rather than protocol logic. These fall to Gleam (type-safe, validated at the boundary) or Elixir/Erlang (via extern declarations). The boundary is clean — Vor handles the protocol layer where verification matters, Gleam/Elixir handles the data layer where expressiveness matters.

## When Things Break

**Safety invariant violated at compile time:** compilation fails with a clear error pointing to the specific handler and state that violates the property.

**Unsupported proven invariant:** compilation fails. The compiler rejects invariant bodies it cannot analyze rather than silently accepting them.

**Type mismatch at Gleam boundary:** the compiler warns when an extern declaration doesn't match Gleam's actual function signature — wrong arity, wrong parameter types, or wrong return type.

**Liveness invariant violated at runtime:** the resilience handler fires — transitioning state, broadcasting recovery messages, or escalating. Violations are observable events, not silent failures.

**Escape hatch crashes:** extern call failures are caught by try/catch wrappers. The agent's OTP supervision handles recovery.

**Protocol mismatch:** the compiler rejects systems where connected agents' send/accept declarations don't match on message tags or field names.

## Intellectual Heritage

**Erlang/OTP** (processes, fault tolerance, hot code loading — Vor's runtime foundation) · **TLA+** (temporal logic, safety/liveness, specification-first design — Vor's verification foundation, also used to verify Vor's own verifier) · **Prolog & miniKanren** (relational programming, bidirectional computation) · **Alloy** (first-order relational logic — the only other formal tool with first-class relations).

## Design Principles

**The spec is the program.** No separate implementation artifact. No drift.

**Relations for knowledge, handlers for effects.** Bidirectional computation where it fits; explicit directionality where effects demand it.

**Guarantee tiers are explicit.** Every property is labeled proven or monitored. The compiler fails closed — it never claims to verify what it can't.

**Failure is first-class.** Invariants can be violated. Resilience handlers define what happens. Recovery paths are verified.

**The BEAM is the foundation.** Vor doesn't replace OTP — it compiles to OTP and adds verification above it.

**Clean language boundaries.** Vor for verified coordination. Gleam for type-safe data processing. Elixir for OTP infrastructure. Each language does what it does best, with validated boundaries between them.

---

*vorlang.org  ·  Targets: BEAM/OTP  ·  License: MIT  ·  Status: Working compiler, 287+ tests, five examples including Raft and CRDTs*
