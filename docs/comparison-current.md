# Vor — Paradigm Comparison

## Two approaches to building software

The "Mainstream" column describes the dominant paradigm (Java, Python, TypeScript, Go). Erlang and Elixir already solve many of these problems — immutable data, process isolation, message passing, supervision. Vor builds on the same BEAM runtime and adds a verification layer that OTP doesn't provide.

|  | **Mainstream** (Imperative/OOP) | **Vor** (Declarative, BEAM-native) |
|---|---|---|
| **Primary artifact** | Source code (functions, classes, modules) | Behavioral specification (.vor file). No separate implementation |
| **State model** | Mutable variables, objects, shared memory | Relational knowledge (timeless) + process state (temporal), explicitly separated |
| **Correctness** | Tests, mostly after the fact | Three levels: proven (compile-time), model-checked (multi-agent exploration), monitored (runtime recovery) |
| **Spec vs. impl gap** | Large. Design docs drift immediately | Zero. The spec compiles directly to BEAM bytecode. Model checker runs on the same code |
| **Multi-agent verification** | Ad-hoc testing, Jepsen if you're lucky | Product state exploration via `mix vor.check`. All message interleavings checked. Raft proven in 1,001 states |
| **Failure handling** | Try/catch, error codes | Declared resilience policies. Recovery handlers verified against safety invariants |
| **Escape hatches** | N/A | Gleam externs with type-validated boundary. Proven invariants cannot depend on extern results |
| **Maturity** | Decades of tooling | 351+ tests, embedded model checker, all five examples fully native. Active development |

### What about Erlang and Elixir?

Erlang and Elixir already occupy a different position from the mainstream column above. They have immutable data, lightweight processes, message passing, "let it crash" supervision, and hot code reloading. If you're already on the BEAM, you've solved the concurrency and fault tolerance problems that plague mainstream languages.

What Erlang and Elixir don't have is verification of the things that go wrong even on the BEAM: state machines with missing handlers or illegal transitions, stuck processes that never terminate, protocol mismatches between GenServers, and distributed coordination bugs where message ordering produces impossible states.

Vor doesn't replace OTP — it compiles to OTP. A Vor agent is a gen_server or gen_statem at runtime. Vor adds the layer above: the state machine is declared and verified, the protocol is checked, the invariants are enforced, and multi-agent systems are model-checked.

### How Vor differs from verification tools

**The two-artifact problem.** The standard approach — verify in TLA+ [1], implement in a production language — introduces drift. Specifications and implementations diverge. Experience at Amazon [3] and Microsoft [4] reports that specifications frequently become stale.

**Stateright showed another way.** Stateright [5] embeds a model checker in a Rust actor library. Vor takes this further: the model checker is in the compiler, sharing an IR with the code generator. The checker and the codegen read the same intermediate representation — there is no separate trait to implement, no alternate code path that can diverge.

**Erla+** [6] translates PlusCal into TLA+ and executable Erlang, addressing drift by generating both from one source. Erla+ starts from a specification language; Vor's source is a programming language that is also a checkable specification.

The tradeoff is real: TLA+'s model checker handles richer temporal properties and larger state spaces. But Vor checks properties against the actual executable code, not a separate model.

### How Vor works with Gleam

Vor is designed as a two-language stack with Gleam:

- **Vor** handles the coordination layer — state machines, protocols, invariants, model checking. All five examples are fully native.
- **Gleam** handles complex data processing when needed — type-safe transformations called through Vor's validated `extern gleam` boundary.

They don't compete. Vor verifies coordination (state transitions, message interleavings, protocol compatibility). Gleam verifies data processing (types, patterns, error handling). The boundary between them is type-checked at compile time.

| Concern | Vor catches | Gleam catches |
|---|---|---|
| Illegal state transitions | Yes — compile time | No |
| Missing message handlers | Yes — compile time | No |
| Protocol mismatches | Yes — compile time | No |
| Distributed coordination bugs | Yes — model checking | No |
| Stuck processes | Yes — runtime monitoring | No |
| Type errors in data processing | Yes — internal type tracking | Yes — compile time |
| Null crashes | No | Yes |
| CRDT merge correctness | Yes — verified merge operations | No |
| Cross-language boundary | Yes — Gleam interface validation | N/A |

### The AI question

Vor's declarative structure means AI-generated code gets the same compiler checks as human-written code. Invariants must hold, protocols must match, handlers must cover all messages, and the model checker explores the same interleavings regardless of who wrote the code. All five examples were developed with AI assistance. The compiler caught real bugs in AI-generated code during development.

### The honest risks

**Expressiveness limits.** Vor's expression language is simpler than Erlang, Elixir, or Gleam. All five examples are expressible natively, but more complex data operations require Gleam externs. The boundary between "what Vor handles" and "what Gleam handles" requires judgment.

**State space explosion.** Multi-agent model checking uses cone-of-influence abstraction and symmetry reduction, but large systems may exceed tractable bounds. Vor reports this honestly.

**The extern trust boundary.** Proven invariants cannot depend on extern results. The more logic behind externs, the less the model checker can see. The goal is to keep protocol logic in Vor.

**Adoption.** Vor's audience is small. VorDB is the first real consumer.

---

*vorlang.org  ·  Targets: BEAM/OTP  ·  License: MIT  ·  Status: 351+ tests, all examples native, Raft proven in 1,001 states*
