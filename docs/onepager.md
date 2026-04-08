# Vor

**A BEAM-native language with relations, protocols, and verifiable invariants**

*Relations for knowledge, handlers for effects  ·  The spec is the program*

---

## What is Vor?

Vor is a programming language that compiles to Erlang/OTP on the BEAM — the same compilation model as Elixir. At runtime, a Vor agent is indistinguishable from a hand-written gen_server or gen_statem. Erlang, Elixir, Gleam, and Vor coexist seamlessly in one VM.

What Vor adds is a verification layer that OTP doesn't provide. You declare state machines with enumerated states, message protocols with typed interfaces, and invariants as temporal logic properties. The compiler verifies these declarations — checking that state transitions are valid, that protocols are compatible, and that safety properties hold — before producing BEAM bytecode. For multi-agent systems, `mix vor.check` model-checks system-level invariants by exploring all reachable combined states through all possible message interleavings. Named for the Norse goddess who witnesses oaths, Vor programs are binding declarations that the compiler enforces.

## Core Primitives

**State Declarations** — Explicit enumeration of valid states. When present, the agent compiles to a gen_statem. The compiler has the complete state graph and can verify transitions against safety invariants. Non-enum state fields (integers, atoms, maps, lists) are stored in the gen_statem data map or the gen_server state map, with type-appropriate defaults.

**Protocols** — Typed message interfaces for agents. `accepts` declares what an agent receives. `emits` declares synchronous replies. `sends` declares messages forwarded to other agents. Protocol composition is checked at compile time when agents are wired together in a system block — tag mismatches and field name mismatches are compile errors.

**Invariants** — Temporal properties in the tradition of TLA+. Safety invariants ("this must never happen") are tagged `proven` and verified at compile time by exhaustive graph traversal. Liveness invariants ("this must eventually happen") are tagged `monitored` and enforced at runtime via gen_statem state timeouts. The compiler rejects `proven` invariants it cannot verify — it fails closed, never silently accepting unverifiable properties. Proven invariants cannot depend on extern results.

**Multi-Agent Model Checking** — System-level safety invariants are verified by product state exploration via `mix vor.check`. The explorer constructs all reachable combined states, systematically delivers messages in every possible order, and checks invariants at every reachable state. Counterexample traces show the exact message interleaving that causes a violation. Only state-changing successors are explored. Bounded verification reports honestly when the state space exceeds configured limits.

**Resilience** — Declarative failure handling. What happens when a liveness invariant is violated, when a process is stuck, when recovery is needed. Resilience handlers are generated as regular handler clauses and included in the state graph — the safety verifier checks them too, ensuring the recovery path doesn't introduce new bugs.

**Relations** — Bidirectional mappings for knowledge and data transformation. Define a relation once; query it in any direction. Fact-based relations support multi-directional lookup. Equation-based relations are automatically inverted at compile time — define `F = C * 9/5 + 32`, query with either variable. The solver handles the directionality.

**Multi-Agent Systems** — Agents are wired together in `system` blocks with named instances, parameters, and connection topology. The compiler generates an OTP Supervisor and Registry. `send` delivers messages to specific named agents. `broadcast` delivers to all connected agents. Agents discover each other via the Registry and automatically re-register on restart.

**Init Handlers** — `on :init` runs once during agent startup, before accepting messages. Supports extern calls for loading persisted state, parameter-based initialization, and setup logic. No race window between agent start and initial state.

**Extern Declarations** — Escape hatches to Erlang, Elixir, and Gleam for anything Vor doesn't handle natively: data processing, database access, HTTP calls, string manipulation. Extern calls are untrusted by default — wrapped in try/catch. A `proven` invariant whose verification path depends on an extern result is rejected at compile time, consistent with fail-closed philosophy.

**Gleam Extern Support** — First-class interop with Gleam modules via `extern gleam` blocks. Gleam's slash-separated module paths (`vordb/counter.increment()`) compile directly to BEAM module calls (`'vordb@counter':increment()`). When Gleam's `package-interface.json` is available, the Vor compiler validates extern declarations against Gleam's actual type signatures — catching arity mismatches, parameter type mismatches, and return type mismatches at compile time. This creates a type-checked boundary between Vor's verified coordination layer and Gleam's type-safe data processing layer.

## Type Safety Strategy

Vor's approach to type safety is layered and complementary to the BEAM ecosystem:

**Coordination verification (today).** The compiler proves state machine properties, checks protocol compatibility, and verifies handler coverage. This catches the bugs that type systems can't — illegal state transitions, missing message handlers, stuck processes.

**Gleam boundary validation (today).** Extern declarations are validated against Gleam's type metadata. The extern boundary — where Vor's verified coordination meets Gleam's typed data processing — is type-checked in both directions.

**Internal type tracking (today).** The compiler propagates types through handler body expressions, using declared state field types and built-in operation signatures. Guaranteed crashes (map operations on integers, arithmetic on maps) are caught at compile time. Gleam extern return types flow through the handler body, extending type coverage beyond the extern boundary.

**Long-term direction.** E-graph-based equality saturation for verifying CRDT merge properties (commutativity, associativity, idempotency). User-defined CRDT merge functions with compiler-verified algebraic properties.

## What's Working

The compiler is real and tested:

- Full pipeline: `.vor` source → Lexer → Parser → AST → IR → Verification → Erlang codegen → BEAM binary
- Compile-time safety verification via state graph traversal
- Multi-agent model checking via product state exploration (`mix vor.check`)
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
- 328+ tests, 9 property-based test suites, adversarial edge case testing, performance benchmarks
- Five working examples with verified invariants and multi-agent coordination
- CRDT examples verified native: G-Counter, PN-Counter, version-based OR-Set — zero extern calls
- Compilation under 5ms for any agent, verification under 2ms for any graph

## Examples

**Distributed lock** — gen_statem with FIFO wait queue using `list_append`/`list_head`/`list_tail`. Proven safety invariant: "never grant the lock while it's held" — the compiler exhaustively verifies this across every reachable state and handler path. Liveness timeout with automatic release via resilience handler. The verification is total: every property claimed is proven, no extern dependencies in the verification path.

**Circuit breaker** — gen_statem with three states (closed/open/half_open). Proven safety invariant: "no forwarding when open." Liveness monitoring for recovery timeout. Another example where the verification is complete — every invariant the compiler claims to check, it checks exhaustively.

**G-Counter CRDT** — fully native (zero externs), periodic gossip via `every`, cluster convergence verified. Demonstrates CRDT merge with `map_merge(:max)`. Merge commutativity and idempotency verified through property-based testing.

**Rate limiter** — gen_server with extern calls to ETS, parameterized limits, per-client tracking. Demonstrates the Vor-Elixir boundary: protocol logic in Vor, storage in Elixir.

**Raft consensus** — three-node cluster with leader election, conditional vote granting, and leader promotion on majority. Demonstrates multi-agent coordination with native `send` and `broadcast`. System-level invariant "at most one leader" verified via `mix vor.check` — the model checker explores message interleavings across the cluster. Each node's local state machine is also verified with single-agent invariants.

## Boundaries

Vor is suited to anything involving state machines, message protocols, or correctness requirements: telecom protocol stacks, distributed consensus, CRDT-based data stores, payment processing, workflow orchestration, IoT coordination. Its primitives add particular value where getting the state machine wrong has real consequences.

**What Vor verifies:** single-agent state machine properties (safety invariants proven at compile time), multi-agent system properties (via product state exploration), handler coverage, protocol composition across connected agents, liveness with declared recovery, type correctness through handler bodies.

**What Vor monitors:** liveness invariants at runtime, with automatic recovery. Violations are observable events, not silent failures.

**What Vor delegates:** complex data transformation, database access, HTTP, string processing, and anything that's data processing rather than protocol logic. These fall to Gleam (type-safe, validated at the boundary) or Elixir/Erlang (via extern declarations). The boundary is clean — Vor handles the protocol layer where verification matters, Gleam/Elixir handles the data layer where expressiveness matters.

## When Things Break

**Safety invariant violated at compile time:** compilation fails with a clear error pointing to the specific handler and state that violates the property.

**System-level invariant violation found by model checker:** `mix vor.check` reports the exact counterexample trace — which message was delivered to which agent in which order to produce the violating state.

**Proven invariant depends on extern:** compilation fails. A `proven` invariant must be verifiable from Vor-visible code alone.

**Type mismatch at Gleam boundary:** the compiler warns when an extern declaration doesn't match Gleam's actual function signature.

**Type error in handler body:** the compiler reports guaranteed crashes (map operations on integers, arithmetic on maps) at compile time.

**Liveness invariant violated at runtime:** the resilience handler fires — transitioning state, broadcasting recovery messages, or escalating.

**Protocol mismatch:** the compiler rejects systems where connected agents' send/accept declarations don't match on message tags or field names.

## Intellectual Heritage

**Erlang/OTP** (processes, fault tolerance, hot code loading — Vor's runtime foundation) · **TLA+** (temporal logic, safety/liveness, specification-first design — Vor's verification foundation, also used to verify Vor's own verifier) · **Stateright** (embedded model checking on executable code — inspiration for multi-agent verification) · **Prolog & miniKanren** (relational programming, bidirectional computation) · **Alloy** (first-order relational logic — the only other formal tool with first-class relations).

## Design Principles

**The spec is the program.** No separate implementation artifact. No drift.

**Guarantee tiers are explicit.** Every property is labeled proven or monitored. The compiler fails closed — it never claims to verify what it can't.

**The extern boundary is a trust boundary.** Proven invariants cannot depend on extern results. Extern calls are wrapped in try/catch. Gleam externs are type-validated. The boundary between verified and unverified code is explicit, enforced, and never silently crossed.

**Failure is first-class.** Invariants can be violated. Resilience handlers define what happens. Recovery paths are verified.

**The BEAM is the foundation.** Vor doesn't replace OTP — it compiles to OTP and adds verification above it.

**Clean language boundaries.** Vor for verified coordination. Gleam for type-safe data processing. Elixir for OTP infrastructure. Each language does what it does best, with validated boundaries between them.

---

*vorlang.org  ·  Targets: BEAM/OTP  ·  License: MIT  ·  Status: Working compiler, 328+ tests, embedded model checker, five examples with verified invariants*
