# Vor — Paradigm Comparison

## Two approaches to building software

The "Mainstream" column describes the dominant paradigm (Java, Python, TypeScript, Go). Erlang and Elixir already solve many of these problems — immutable data, process isolation, message passing, supervision. Vor builds on the same BEAM runtime and adds a verification layer that OTP doesn't provide.

|  | **Mainstream** (Imperative/OOP) | **Vor** (Declarative, BEAM-native) |
|---|---|---|
| **Primary artifact** | Source code (functions, classes, modules) | Behavioral specification (.vor file). No separate implementation |
| **Computation primitive** | Functions (unidirectional input → output) | Relations (bidirectional) + directional handlers for effects |
| **State model** | Mutable variables, objects, shared memory | Relational knowledge (timeless) + process state (temporal), explicitly separated |
| | | |
| **Correctness approach** | Tests (unit, integration, e2e). Mostly after the fact | Three levels: proven (compiler-verified single-agent), model-checked (multi-agent product state exploration), monitored (runtime enforcement with declared recovery) |
| **Invariants** | Implicit in code logic. Asserts, type checks | First-class temporal logic (TLA+-style). Safety + liveness. Each tagged with guarantee tier. Compiler fails closed on unverifiable properties |
| **Spec vs. impl gap** | Large. Design docs drift from code immediately | Zero. The spec compiles directly to BEAM bytecode. Model checker runs on the same code. No drift possible |
| | | |
| **Type safety** | Static types (Java, Go, TypeScript) or dynamic (Python, Ruby) | Layered: coordination verification (proven), Gleam boundary validation (type-checked), internal type tracking (compile-time crash detection) |
| **Concurrency model** | Threads, locks, async/await. Error-prone shared state | Agents as OTP processes. Topology declared in system blocks. Protocols checked at compile time |
| **Failure handling** | Try/catch, error codes. Ad-hoc per codebase | Declared resilience policies. Recovery handlers are verified against safety invariants. Violations are observable events |
| **Composition** | Function calls, imports, dependency injection | Protocol unification. Agents compose if message tags and field names align. Compiler checks compatibility |
| | | |
| **Multi-agent verification** | Ad-hoc testing, Jepsen if you're lucky | Product state exploration via `mix vor.check`. All message interleavings checked. State abstraction + symmetry reduction. Raft proven in 1,001 states |
| **Change process** | Edit code → test → review → deploy | Update spec → compiler re-verifies → model checker re-explores → BEAM binary reloaded |
| **Debugging** | Stack traces, breakpoints, print statements | Invariant violation traces. Counterexample traces showing exact message interleavings. State graph extraction and visualization |
| | | |
| **Key difficulty** | Complexity scales with human cognitive limits. Concurrency bugs. Integration debt | Expression language limits require extern calls for data operations. State space explosion for large multi-agent systems (mitigated by abstraction + symmetry). Conditional codegen complexity in gen_statem |
| **Escape hatches** | N/A — everything is manual | Drop to Erlang/Elixir/Gleam via extern declarations. Untrusted by default — try/catch wrapped, proven invariants cannot depend on extern results. Gleam externs are type-validated at the boundary |
| **Maturity** | Decades of tooling, libraries, talent pool | Working compiler with 349+ tests, TLA+-verified verifier, embedded model checker proving Raft in 1,001 states, five examples with verified invariants. Compilation <5ms, verification <2ms. Active development |

### What about Erlang and Elixir?

Erlang and Elixir already occupy a different position from the mainstream column above. They have immutable data, lightweight processes, message passing, "let it crash" supervision, and hot code reloading. If you're already on the BEAM, you've solved the concurrency and fault tolerance problems that plague mainstream languages.

What Erlang and Elixir don't have is verification of the things that go wrong even on the BEAM: state machines with missing handlers or illegal transitions, stuck processes that never terminate, protocol mismatches between GenServers where one side sends a message the other doesn't expect, distributed coordination bugs where message ordering produces impossible states, and invariants that exist only as comments or tests rather than as compiler-checked properties.

Vor doesn't replace OTP — it compiles to OTP. A Vor agent is a gen_server or gen_statem at runtime, supervised and distributed like any other BEAM process. Vor adds the layer above: the state machine is declared and verified, the protocol is checked at compile time, the invariants are enforced, and multi-agent systems are model-checked. Everything below that layer is the same BEAM you already trust.

### How Vor differs from verification tools

A reasonable alternative to Vor: use TLA+ or P to verify your design, then implement in Erlang/Elixir. This is essentially the workflow Amazon uses (TLA+ for design, Java/Rust for implementation) and Microsoft advocates (P for modeling, C# for production). Why isn't this enough?

**The two-artifact problem.** You now have a TLA+ spec and an Erlang implementation. They're written in different languages, live in different files, and use different tools. On day one they match. On day thirty, someone fixes a production bug by editing the Erlang code without updating the TLA+ spec. On day three hundred, nobody trusts the spec anymore and it becomes shelfware.

**Stateright showed another way.** Stateright (Rust) demonstrated that an embedded model checker — one that runs on the actual implementation code, not a separate spec — is practical and effective. Vor brings this approach to the BEAM. The `.vor` file is both the specification and the implementation. `mix vor.check` model-checks the real code, exploring message interleavings across agents and reporting counterexample traces when invariants are violated. No separate spec to drift.

**Erla+: the closest comparable work.** Erla+ (presented at the Erlang Workshop at ICFP 2024) translates PlusCal models into both TLA+ for verification and executable Erlang programs. It directly addresses the two-artifact problem by generating both artifacts from one source. The key difference from Vor: Erla+ starts from PlusCal (a specification language) and generates Erlang. Vor IS the code — the `.vor` file is both the specification and the implementation, written in a language designed for programming, not for specification.

**What Vor does instead.** In Vor, there is one artifact. The state machine declaration, the handler behavior, the invariants, and the executable code are all in the same `.vor` file, in the same language, processed by the same compiler. The model checker runs on the same code that runs in production. When you change a handler, the compiler re-checks it against the invariants and the model checker re-explores the system. Nothing drifts because there's nothing to drift from.

The Raft cluster invariant "at most one leader" is proven by exploring 1,001 states with symmetry reduction (8,008 without). The model checker uses state abstraction to track only invariant-relevant fields, integer saturation to bound numeric dimensions, and symmetry reduction to collapse equivalent agent permutations. These techniques — standard in model checking research — make verification of real protocols tractable.

The tradeoff is real: TLA+'s model checker (TLC) is more mature, more expressive, and handles richer temporal properties than Vor's explorer. But the properties Vor can check are checked against the actual executable code, not against a separate model that might not match reality.

### How Vor complements Gleam

**Gleam** asks "what if Erlang had types?" Gleam adds static type safety to the BEAM with a clean, modern syntax and excellent developer experience.

**Vor** asks "what if your state machine was proven correct — and your distributed system was model-checked?" Vor adds compile-time verification of state machine properties, protocol compatibility, temporal invariants, and multi-agent model checking.

They don't compete — they complement each other. Vor verifies the coordination layer. Gleam verifies the data processing layer. Together they cover both classes of bugs that plague distributed systems.

**The Vor-Gleam boundary.** Vor's `extern gleam` support creates a type-checked interface between the two languages. The boundary between verified coordination (Vor) and type-safe data processing (Gleam) is itself verified.

| Concern | Vor catches | Gleam catches |
|---|---|---|
| Illegal state transitions | Yes — compile time | No concept of state machines |
| Missing message handlers | Yes — compile time | No concept of protocol coverage |
| Protocol mismatches between agents | Yes — compile time | No inter-module contract checking |
| Distributed coordination bugs | Yes — model checking | No multi-agent verification |
| Stuck processes | Yes — runtime monitoring | No concept of liveness |
| Type errors in data processing | Yes — internal type tracking | Yes — compile time |
| Missing error handling | Partial (emit completeness) | Yes — exhaustive patterns |
| Null crashes | No | Yes — no null type |
| CRDT merge correctness | Yes — verified merge operations | No — types correct but semantics unchecked |
| Cross-language type boundary | Yes — Gleam interface validation | N/A |

### The AI question

Vor's declarative structure — where the spec is the program and properties are first-class — means that AI-generated code gets the same compiler checks as human-written code. Invariants must hold, protocols must match, handlers must cover all accepted messages, and the model checker explores the same message interleavings regardless of who wrote the code.

All five examples were developed with AI assistance. The compiler caught real bugs in AI-generated code during development. The multi-agent model checker found a false positive in the Raft example that led to moving a critical check from an extern call into native Vor arithmetic — improving the verification story. This isn't a feature of Vor; it's a consequence of the design.

### The honest risks

**Expressiveness limits.** Vor's handler expression language is simpler than Erlang, Elixir, or Gleam. Complex data operations require extern calls. This is by design — Vor handles the protocol layer, Gleam/Elixir handles the data layer — but it means Vor programs are always hybrid.

**State space explosion.** Multi-agent model checking faces the same fundamental challenge as TLA+/TLC. State abstraction, integer bounding, and symmetry reduction help — the Raft cluster is proven in 1,001 states — but larger systems with more agents, more states, or richer data may exceed tractable bounds. Vor reports this honestly and never claims exhaustive proof when bounds are exceeded.

**The extern trust boundary.** Proven invariants cannot depend on extern results. The more logic behind externs, the less the compiler and model checker can verify. The goal is to keep protocol logic in Vor where verification reaches it.

**Adoption.** New programming languages face a steep adoption curve. Vor's audience is small. A CRDT-based distributed database (VorDB) is the first real consumer, driving language features through practical use.

If Vor never gains adoption, it's still a working demonstration that verification, model checking, and execution can live in one artifact on a production runtime. If it does gain adoption, the BEAM ecosystem gets a verification layer it's never had.

---

*vorlang.org  ·  Targets: BEAM/OTP  ·  License: MIT  ·  Status: Working compiler, 349+ tests, Raft proven in 1,001 states*
