# Vor — Paradigm Comparison

## Two approaches to building software

The "Mainstream" column describes the dominant paradigm (Java, Python, TypeScript, Go). Erlang and Elixir already solve many of these problems — immutable data, process isolation, message passing, supervision. Vor builds on the same BEAM runtime and adds a verification layer that OTP doesn't provide.

|  | **Mainstream** (Imperative/OOP) | **Vor** (Declarative, BEAM-native) |
|---|---|---|
| **Primary artifact** | Source code (functions, classes, modules) | Behavioral specification (.vor file). No separate implementation |
| **Computation primitive** | Functions (unidirectional input → output) | Relations (bidirectional) + directional handlers for effects |
| **State model** | Mutable variables, objects, shared memory | Relational knowledge (timeless) + process state (temporal), explicitly separated |
| | | |
| **Correctness approach** | Tests (unit, integration, e2e). Mostly after the fact | Two tiers: proven (compiler-verified via graph traversal) and monitored (runtime enforcement with declared recovery) |
| **Invariants** | Implicit in code logic. Asserts, type checks | First-class temporal logic (TLA+-style). Safety + liveness. Each tagged with guarantee tier. Compiler fails closed on unverifiable properties |
| **Spec vs. impl gap** | Large. Design docs drift from code immediately | Zero. The spec compiles directly to BEAM bytecode. No drift possible |
| | | |
| **Type safety** | Static types (Java, Go, TypeScript) or dynamic (Python, Ruby) | Layered: coordination verification (proven), Gleam boundary validation (type-checked), internal type tracking (in progress) |
| **Concurrency model** | Threads, locks, async/await. Error-prone shared state | Agents as OTP processes. Topology declared in system blocks. Protocols checked at compile time |
| **Failure handling** | Try/catch, error codes. Ad-hoc per codebase | Declared resilience policies. Recovery handlers are verified against safety invariants. Violations are observable events |
| **Composition** | Function calls, imports, dependency injection | Protocol unification. Agents compose if message tags and field names align. Compiler checks compatibility |
| | | |
| **Multi-agent coordination** | Ad-hoc messaging, shared databases, message queues | System blocks with Registry-based discovery. Send for directed messages, broadcast for fan-out. Automatic re-registration on restart |
| **Change process** | Edit code → test → review → deploy | Update spec → compiler re-verifies → BEAM binary reloaded. Invariants checked on every change |
| **Debugging** | Stack traces, breakpoints, print statements | Invariant violation traces. Compiler trace shows each pipeline stage. State graph extraction and visualization |
| | | |
| **Key difficulty** | Complexity scales with human cognitive limits. Concurrency bugs. Integration debt | Expression language limits require extern calls for data operations. Verification limited to single-agent local properties. Conditional codegen complexity in gen_statem |
| **Escape hatches** | N/A — everything is manual | Drop to Erlang/Elixir/Gleam via extern declarations. Untrusted by default — try/catch wrapped, compiler warns if proven invariants depend on extern results. Gleam externs are type-validated at the boundary |
| **Maturity** | Decades of tooling, libraries, talent pool | Working compiler with 287+ tests, TLA+-verified verifier, five examples including Raft consensus and CRDTs. Compilation <5ms, verification <2ms. Active development |

### What about Erlang and Elixir?

Erlang and Elixir already occupy a different position from the mainstream column above. They have immutable data, lightweight processes, message passing, "let it crash" supervision, and hot code reloading. If you're already on the BEAM, you've solved the concurrency and fault tolerance problems that plague mainstream languages.

What Erlang and Elixir don't have is verification of the things that go wrong even on the BEAM: state machines with missing handlers or illegal transitions, stuck processes that never terminate, protocol mismatches between GenServers where one side sends a message the other doesn't expect, and invariants that exist only as comments or tests rather than as compiler-checked properties.

Vor doesn't replace OTP — it compiles to OTP. A Vor agent is a gen_server or gen_statem at runtime, supervised and distributed like any other BEAM process. Vor adds the layer above: the state machine is declared and verified, the protocol is checked at compile time, and the invariants are enforced. Everything below that layer is the same BEAM you already trust.

### How Vor differs from verification tools

A reasonable alternative to Vor: use TLA+ or P to verify your design, then implement in Erlang/Elixir. This is essentially the workflow Amazon uses (TLA+ for design, Java/Rust for implementation) and Microsoft advocates (P for modeling, C# for production). Why isn't this enough?

**The two-artifact problem.** You now have a TLA+ spec and an Erlang implementation. They're written in different languages, live in different files, and use different tools. On day one they match. On day thirty, someone fixes a production bug by editing the Erlang code without updating the TLA+ spec. On day ninety, someone adds a feature to the spec but the implementation diverges in a subtle way. On day three hundred, nobody trusts the spec anymore and it becomes shelfware. This isn't hypothetical — it's the documented experience of almost every team that adopts formal methods alongside a production codebase. The spec drifts from the code because nothing enforces their alignment.

**Stubs aren't implementations.** A verified TLA+ model can tell you that your state machine design is correct. It can generate the skeleton of a gen_statem with the right states and transitions. But the skeleton is empty — someone still has to write the handler bodies, the timer management, the error responses, the data transformations. That's where most bugs live. The stub gives you correct structure but unverified behavior. It's like having a verified blueprint but no building inspector.

**Verification and execution live in different worlds.** TLA+ checks properties against a mathematical model. The Erlang code runs on the BEAM. Between them is a manual translation step that no tool verifies. Did the developer faithfully translate every TLA+ state transition into a gen_statem clause? Did they handle every message that the TLA+ model says can arrive in each state? Did they implement the timer backoff exactly as the model specifies? These are exactly the questions where bugs hide, and no tool answers them.

**The tools don't share semantics.** TLA+ thinks in terms of state predicates and temporal formulas. Erlang thinks in terms of processes and message passing. P thinks in terms of events and state machines. Each tool has its own abstraction, and translating between them is a manual, error-prone process. The developer must be fluent in both the verification language and the implementation language, and must mentally maintain the mapping between them. This is why formal methods adoption remains low despite decades of advocacy — the cognitive overhead of maintaining two mental models is high.

**Erla+: the closest comparable work.** Erla+ (presented at the Erlang Workshop at ICFP 2024) translates PlusCal models into both TLA+ for verification and executable Erlang programs. It directly addresses the two-artifact problem by generating both artifacts from one source. The key difference from Vor: Erla+ starts from PlusCal (a specification language) and generates Erlang. Vor IS the code — the `.vor` file is both the specification and the implementation, written in a language designed for programming, not for specification. Erla+ gives you TLA+'s full model checking power but constrains you to PlusCal's expressiveness. Vor gives you a practical programming language with focused verification built in.

**What Vor does instead.** In Vor, there is one artifact. The state machine declaration, the handler behavior, the invariants, and the executable code are all in the same `.vor` file, in the same language, processed by the same compiler. When you change a handler, the compiler re-checks it against the invariants. When you add an invariant, the compiler verifies it against the existing handlers. Nothing drifts because there's nothing to drift from. The verified model and the running code are the same thing.

The tradeoff is real: existing verification tools (TLA+, SPIN, Alloy) are more mature, more expressive, and better understood than Vor's invariant system. Vor's compile-time verification is currently limited to local single-agent properties — it can't verify distributed invariants like "at most one leader per term" across a cluster. But the properties it can check are checked against the actual executable code, not against a separate model that might not match reality. A weaker guarantee about the real system beats a stronger guarantee about a model that's drifted from the system.

### How Vor complements Gleam

**Gleam** asks "what if Erlang had types?" Gleam adds static type safety to the BEAM with a clean, modern syntax and excellent developer experience. It catches type errors, enforces exhaustive pattern matching, eliminates null-related crashes, and ensures every error case is handled.

**Vor** asks "what if your state machine was proven correct?" Vor adds compile-time verification of state machine properties, protocol compatibility, and temporal invariants. It catches illegal state transitions, missing message handlers, stuck processes, and protocol mismatches.

They don't compete — they complement each other. Vor verifies the coordination layer (state machines, protocols, invariants). Gleam verifies the data processing layer (types, patterns, error handling). Together they cover both classes of bugs that plague distributed systems.

**The Vor-Gleam boundary.** Vor's `extern gleam` support creates a type-checked interface between the two languages. The Vor compiler reads Gleam's `package-interface.json` and validates that extern declarations match Gleam's actual function signatures. This means the boundary between verified coordination (Vor) and type-safe data processing (Gleam) is itself verified — no untyped gap between the layers.

| Concern | Vor catches | Gleam catches |
|---|---|---|
| Illegal state transitions | Yes — compile time | No concept of state machines |
| Missing message handlers | Yes — compile time | No concept of protocol coverage |
| Protocol mismatches between agents | Yes — compile time | No inter-module contract checking |
| Stuck processes | Yes — runtime monitoring | No concept of liveness |
| Type errors in data processing | In progress (internal type tracking) | Yes — compile time |
| Missing error handling | Partial (emit completeness) | Yes — exhaustive patterns |
| Null crashes | No | Yes — no null type |
| CRDT merge correctness | Yes — verified merge operations | No — types correct but semantics unchecked |
| Cross-language type boundary | Yes — Gleam interface validation | N/A |

### The AI question

Vor's declarative structure — where the spec is the program and properties are first-class — is designed to be AI-friendly. An AI writing a Vor program gets its work checked by the compiler: invariants must hold, protocols must match, handlers must cover all accepted messages. The compiler catches the AI's mistakes the same way it catches a human's.

This isn't AI synthesis in the speculative sense of "AI generates implementations from properties." It's more practical: AI writes `.vor` files the same way it writes `.py` or `.ex` files, but the Vor compiler provides stronger guarantees about what it produces. The spec-as-program principle means there's no gap between what the AI was asked to build and what the compiler verifies. All five examples — rate limiter, circuit breaker, Raft, G-Counter, and distributed lock — were developed with AI assistance. The compiler caught real bugs in AI-generated code during development.

Full AI synthesis — where the human provides only properties and the AI provides the implementation — is part of the language design vision but not yet implemented. The verification story works today without it.

### The honest risks

**Expressiveness limits.** Vor's handler expression language is simpler than Erlang, Elixir, or Gleam. Complex data operations (list iteration, map traversal, string processing) require extern calls. This is by design — Vor handles the protocol layer, Gleam/Elixir handles the data layer — but it means Vor programs are always hybrid. The boundary between "what Vor verifies" and "what Gleam/Elixir does" requires judgment.

**Single-agent verification.** Vor can verify properties of individual agents but not distributed properties across a cluster. The Raft example verifies that each node's state machine is locally correct, but "at most one leader per term" — the key Raft safety property — requires reasoning about message interleavings across agents, which is exactly what TLA+ does well and Vor doesn't do yet. Multi-agent runtime monitoring is a planned direction.

**Adoption.** New programming languages face a steep adoption curve regardless of technical merit. Vor's audience — BEAM developers who need verification, or formal methods practitioners who need executable specs — is small. The project's viability depends on finding the right early users, not on broad appeal. A CRDT-based distributed database (VorDB) is the first real consumer, driving language features through practical use.

If Vor never gains adoption, it's still a working demonstration that verification and execution can live in one artifact on a production runtime. If it does gain adoption, the BEAM ecosystem gets a verification layer it's never had.

---

*vorlang.org  ·  Targets: BEAM/OTP  ·  License: MIT  ·  Status: Working compiler, 287+ tests, five examples including Raft and CRDTs*
