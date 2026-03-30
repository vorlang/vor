# Vor — Paradigm Comparison

## Two approaches to building software

|  | **Mainstream** (Imperative/OOP) | **Vor** (Declarative, BEAM-native) |
|---|---|---|
| **Primary artifact** | Source code (functions, classes, modules) | Behavioral specification (.vor file). No separate implementation |
| **Computation primitive** | Functions (unidirectional input → output) | Relations (bidirectional) + directional handlers for effects |
| **Who writes the code** | Human writes all implementation | Human writes spec; AI synthesizes implementation within declared constraints |
| **State model** | Mutable variables, objects, shared memory | Relational knowledge (timeless) + process state (temporal), explicitly separated |
| | | |
| **Correctness approach** | Tests (unit, integration, e2e). Mostly after the fact | Three tiers: proven (compiler-verified), checked (synthesis-tested), monitored (runtime) |
| **Invariants** | Implicit in code logic. Asserts, type checks | First-class temporal logic (TLA+-style). Safety + liveness. Each tagged with guarantee tier |
| **Spec ↔ impl gap** | Large. Design docs drift from code immediately | Zero. The spec is the implementation. No drift possible |
| | | |
| **Concurrency model** | Threads, locks, async/await. Error-prone shared state | Agents as OTP processes. Topology inferred from protocol compatibility |
| **Failure handling** | Try/catch, error codes. Ad-hoc per codebase | Declared resilience policies. Supervision derived from spec. Violations are observable events |
| **Composition** | Function calls, imports, dependency injection | Protocol unification. Agents compose if message types + behavioral contracts align |
| | | |
| **Change process** | Edit code → test → review → deploy | Update spec → AI re-synthesizes → verify constraints → hot-swap on BEAM |
| **Performance tuning** | Profile → manually optimize hot paths | Performance bounds are constraints. AI selects algorithm. Re-synthesis on drift |
| **Debugging** | Stack traces, breakpoints, print statements | Invariant violation traces. AI explains which constraints led to which behaviors |
| | | |
| **Key difficulty** | Complexity scales with human cognitive limits. Concurrency bugs. Integration debt | AI synthesis is probabilistic. Performance bounds may be unsatisfiable. Re-synthesis risks |
| **Escape hatches** | N/A — everything is manual | Drop to Erlang/Elixir for unconstrained effects, system integration, performance-critical paths |
| **Maturity** | Decades of tooling, libraries, talent pool | Design phase. Compiler not yet built. Research-grade dependencies |

---

## The collapse problem: why AI on mainstream doesn't work

The table above suggests a clean split, but there's a deeper question: can you just layer AI code generation onto mainstream languages? That's what Copilot, Claude Code, Cursor, and every AI coding tool attempts today. The argument for Vor rests on why this approach is structurally limited.

### What AI-on-mainstream looks like now

The current model is: human writes intent in natural language or partial code, AI generates implementation in Python/TypeScript/Java/etc., human reviews, tests, and deploys. This works. It's productive. It's also fundamentally bounded.

### Why it collapses at scale

**The generated code inherits all the problems of the language it's written in.** AI-generated Python still has race conditions, type errors at runtime, implicit state mutations, and dependency hell. The AI doesn't eliminate these failure modes — it just produces them faster. You've traded "slow to write, slow to break" for "fast to write, fast to break." The verification burden shifts from writing to reviewing, but it doesn't shrink.

**Review becomes the bottleneck, and it doesn't scale.** When a human writes code, they build a mental model as they go. When AI generates code, the human must reconstruct that mental model from the output. For small generations this is fine. For large systems, the reviewer is doing harder cognitive work than the original author would have — they're reverse-engineering intent from implementation, which is strictly harder than forward-engineering implementation from intent. As AI generates more code faster, the review queue grows, and either quality drops or velocity drops. You can't escape this tradeoff within the mainstream paradigm.

**The spec-implementation gap widens, not narrows.** AI coding tools generate implementations from informal specifications (natural language prompts, comments, partial code). But informal specs are ambiguous. The AI resolves ambiguity by making choices the human didn't specify. Each unreviewed choice is a latent bug. As systems grow, the accumulated unreviewed choices compound into behavioral drift — the system does something nobody intended, but nobody can point to where it went wrong because there's no formal spec to compare against. The mainstream approach has no mechanism to prevent this.

**Testing AI-generated code with AI-generated tests is circular.** If the AI generates both the implementation and the tests, you've created a closed system that validates itself. The tests encode the same assumptions (and potentially the same misunderstandings) as the code. This looks like coverage without providing actual assurance. The only escape is human-written tests, which brings you back to the review bottleneck.

**Refactoring becomes treacherous.** Mainstream codebases are held together by implicit invariants — assumptions that live in developers' heads, not in the code. AI can't see these invariants. When it refactors, it preserves syntax and tests but may violate unstated assumptions. The more AI-generated code accumulates, the fewer humans understand the implicit invariants, and the more dangerous each change becomes. This is technical debt at machine speed.

### What Vor does differently

Vor's key move is collapsing the spec-implementation gap to zero. There is no implementation to review because there is no separate implementation. The .vor file is both the specification and the source of truth. The AI doesn't generate code for humans to review — it generates BEAM bytecode that is mechanically verified against the spec's constraints before deployment.

This changes the verification problem from "does this code match our intent?" (unbounded, requires human judgment) to "does this output satisfy these constraints?" (bounded, mechanically checkable). The human's job shifts from reviewing code to writing good constraints — which is hard, but it's a well-defined hard, not an open-ended hard.

The constraints don't just catch bugs — they prevent the AI from making unauthorized choices. Every behavioral property must be declared. If the spec is silent on something, the AI either flags the ambiguity or defaults to a safe behavior defined by the language. There's no space for "latent unreviewed choices" to accumulate.

### Why not existing verification tools with IDE integration?

A reasonable alternative to Vor: use TLA+ or P to verify your design, then generate code stubs from the verified model, and fill in the implementation in Erlang/Elixir with IDE support. This is essentially the workflow Amazon uses (TLA+ for design, Java/Rust for implementation) and Microsoft advocates (P for modeling, C# for production). Why isn't this enough?

**The two-artifact problem.** You now have a TLA+ spec and an Erlang implementation. They're written in different languages, live in different files, and use different tools. On day one they match. On day thirty, someone fixes a production bug by editing the Erlang code without updating the TLA+ spec. On day ninety, someone adds a feature to the spec but the implementation diverges in a subtle way. On day three hundred, nobody trusts the spec anymore and it becomes shelfware. This isn't hypothetical — it's the documented experience of almost every team that adopts formal methods alongside a production codebase. The spec drifts from the code because nothing enforces their alignment.

**Stubs aren't implementations.** A verified TLA+ model can tell you that your state machine design is correct. It can generate the skeleton of a gen_statem with the right states and transitions. But the skeleton is empty — someone still has to write the handler bodies, the timer management, the error responses, the data transformations. That's where most bugs live. The stub gives you correct structure but unverified behavior. It's like having a verified blueprint but no building inspector.

**Verification and execution live in different worlds.** TLA+ checks properties against a mathematical model. The Erlang code runs on the BEAM. Between them is a manual translation step that no tool verifies. Did the developer faithfully translate every TLA+ state transition into a gen_statem clause? Did they handle every message that the TLA+ model says can arrive in each state? Did they implement the timer backoff exactly as the model specifies? These are exactly the questions where bugs hide, and the IDE integration doesn't answer them.

**The tools don't share semantics.** TLA+ thinks in terms of state predicates and temporal formulas. Erlang thinks in terms of processes and message passing. P thinks in terms of events and state machines. Each tool has its own abstraction, and translating between them is a manual, error-prone process. The developer must be fluent in both the verification language and the implementation language, and must mentally maintain the mapping between them. This is why formal methods adoption remains low despite decades of advocacy — the cognitive overhead of maintaining two mental models is high.

**What Vor does instead.** In Vor, there is one artifact. The state machine declaration, the handler behavior, the invariants, and the executable code are all in the same `.vor` file, in the same language, processed by the same compiler. When you change a handler, the compiler re-checks it against the invariants. When you add an invariant, the compiler verifies it against the existing handlers. Nothing drifts because there's nothing to drift from. The verified model and the running code are the same thing.

The tradeoff is real: existing verification tools (TLA+, SPIN, Alloy) are more mature, more expressive, and better understood than Vor's invariant system. Vor's compile-time verification is currently limited to local single-agent properties — it can't do everything TLA+ can do. But the properties it can check are checked against the actual executable code, not against a separate model that might not match reality. A weaker guarantee about the real system beats a stronger guarantee about a model that's drifted from the system.

### The honest risk

This only works if the constraint language is expressive enough to capture what matters, and if the AI synthesis is reliable enough to produce correct implementations. Both are open research problems. The vericoding results (82% in Dafny) suggest we're approaching viability but aren't there yet. Vor is a bet that the trajectory continues — that formal specification plus AI synthesis will cross the threshold from "research demo" to "practical tool" within the next few years.

If that bet is wrong, Vor is an interesting language with a good runtime target that can still be used with human-written implementations behind the spec. The spec-as-primary-artifact principle has value independent of whether AI synthesis works perfectly. But if the bet is right, Vor is positioned where the future actually lands — and AI-on-mainstream will be remembered as the transition phase, not the destination.

---

*vorlang.org  ·  Targets: BEAM/OTP  ·  License: Open Source  ·  Status: Design Phase*
