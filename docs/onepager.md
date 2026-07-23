# Vor

**A compilation target for AI agents building distributed systems on the BEAM — verified state machines, checked protocols, chaos testing**

*One file. Proven, instrumented, chaos-tested. No Docker. No Kubernetes.*

---

## What is Vor?

Vor is a programming language that compiles to Erlang/OTP on the BEAM. At runtime, a Vor agent is a standard gen_server or gen_statem. At compile time, the compiler proves safety invariants, checks protocol compatibility, generates telemetry, and produces chaos-testable binaries — all from a single source file.

Designed for AI-speed development: AI agents write the `.vor` file, the compiler checks it, the chaos simulator stress-tests it, and the binary ships pre-instrumented. No human writes invariants separately. No human adds telemetry. No human configures chaos tests. The declarations in the source file drive everything.

## Three tiers of checking

```
mix compile        →  single-agent safety proofs          (ms)
mix vor.check      →  finds multi-agent counterexamples    (seconds)
mix vor.simulate   →  chaos-tests real BEAM processes      (minutes)
```

**Compile-time safety.** The compiler walks every reachable state of a single agent and proves that declared safety invariants hold. Violations fail compilation. A `proven` invariant whose subject is unreachable is a compile error, not a silent pass — the checker reports when it engaged with nothing.

**Multi-agent bug-finding.** `mix vor.check` explores message interleavings across connected agents to surface counterexamples, using cone-of-influence abstraction and integer saturation. It is a bug-finder first — finding a violation is fast; exhaustive proof holds only at small bounds (the state space explodes with message-queue depth) — and it never runs during `mix compile`. It caught that Raft's *global* "at most one leader" was mis-specified (two leaders in different terms is legal Raft); the corrected **per-term** invariant is proven and substantive.

**Chaos simulation.** `mix vor.simulate` starts real BEAM processes, kills them, partitions connections, delays messages, generates client workload, and checks invariants against live state — reporting declared-vs-observed coverage and flagging a run `UNDER-TESTED` if the harness degraded. Inputs (fault schedule, workload) are seeded; the BEAM scheduler and real timers are not, so replay is reliable but not byte-for-byte. No external infrastructure.

## Auto-generated telemetry

The compiler knows every state field, every message type, every transition, and every handler. It generates `:telemetry.execute` calls in the compiled bytecode for:

- Agent start/stop
- Every message received (with tag and current state)
- Every state transition (with old/new values, sensitive fields redacted)
- Every message emitted
- Every protocol constraint violation

Zero instrumentation code. Attach any telemetry backend (Prometheus, StatsD) and every agent is observable.

## Protocol input constraints

```vor
protocol do
  accepts {:transfer, amount: integer} where amount > 0 and amount < 100000
end
```

Constraints are checked at runtime before any handler runs. Invalid messages are rejected with a structured error and a telemetry event. No separate validation library.

## Sensitive fields

```vor
state api_key: binary sensitive
```

Fields marked `sensitive` are automatically redacted in telemetry metadata. The field name still appears (you know a transition happened), the value doesn't.

## Core primitives

**Agents** — state machines with enumerated states, parameterized configuration, and init handlers. Compile to gen_statem (with enum states) or gen_server (without).

**Protocols** — typed message interfaces: `accepts`, `emits`, `sends`. Composition checked at compile time across connected agents. Input constraints via `where` clauses.

**Invariants** — temporal properties with explicit guarantee tiers. `proven` = verified at compile time. `monitored` = enforced at runtime with declared resilience handlers. The compiler fails closed — never silently accepts unverifiable properties.

**System blocks** — multi-agent topologies with named instances and connections. System-level invariants: `count`, `exists`, `for_all`, cross-agent comparisons.

**Relations** — bidirectional mappings with compile-time equation inversion.

**Externs** — escape hatches to Gleam (type-validated), Elixir, or Erlang. Proven invariants cannot depend on extern results.

## What Vor eliminates

Compared to a typical distributed systems stack:

- No separate design specification (the spec is the program)
- No separate, drift-prone design spec — the checker runs on the real code (a bug-finder, not a TLA+ replacement)
- No external chaos testing infrastructure
- No external contract tests (protocol checked at compile time)
- No Docker containers
- No Kubernetes orchestration
- No service mesh
- No inter-service load balancers
- No external message queue
- No serialization between services
- No telemetry instrumentation code
- No external input validation framework
- No manual concurrency primitives
- No Helm charts

What you still need: infrastructure provisioning, reverse proxy for external HTTP, telemetry backend, CI/CD, load testing, secrets management.

## Two-language stack

- **Vor** — coordination: state machines, protocols, invariants, bug-finding, chaos, telemetry
- **Gleam** — data processing when needed, called through type-validated extern boundary

All five examples are fully native Vor. Gleam provides typed library functions for complex data operations when the native expression language isn't sufficient.

## What's working

- Full compiler pipeline to BEAM bytecode
- Three tiers: compile-time proofs, multi-agent bug-finding, chaos simulation
- Vacuity / relevance detection across the checker and the simulator — vacuous `proven` invariants are compile errors
- Auto-generated telemetry for gen_server and gen_statem
- Protocol input constraints with `where` clauses
- Sensitive field redaction
- Raft per-term leader uniqueness proven and substantive at bounded scale (the global variant was mis-specified — a documented war story)
- Chaos simulation with kill, partition, delay, workload, and declared-vs-observed coverage
- 500+ tests, 9 property-based test suites
- All five examples fully native — zero externs
- G-Counter CRDT fully native (zero externs); gossip fires under real timers, though map contents abstract to `:unknown`, so value-level convergence is not checkable
- VorDB as first real consumer

---

*vorlang.org  ·  BEAM/OTP  ·  MIT License  ·  500+ tests*
