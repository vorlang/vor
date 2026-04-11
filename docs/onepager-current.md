# Vor

**A compilation target for AI agents building verified distributed systems on the BEAM**

*One file. Verified, instrumented, chaos-tested. No Docker. No Kubernetes.*

---

## What is Vor?

Vor is a programming language that compiles to Erlang/OTP on the BEAM. At runtime, a Vor agent is a standard gen_server or gen_statem. At compile time, the compiler proves safety invariants, checks protocol compatibility, generates telemetry, and produces chaos-testable binaries — all from a single source file.

Designed for AI-speed development: AI agents write the `.vor` file, the compiler verifies it, the chaos simulator stress-tests it, and the binary ships pre-instrumented. No human writes invariants separately. No human adds telemetry. No human configures chaos tests. The declarations in the source file drive everything.

## Three-level verification

```
mix compile        →  single-agent safety proofs          (ms)
mix vor.check      →  multi-agent model checking          (seconds)
mix vor.simulate   →  chaos testing on real processes     (minutes)
```

**Compile-time safety.** The compiler walks every reachable state and proves that declared safety invariants hold. Violations fail compilation.

**Multi-agent model checking.** `mix vor.check` explores all message interleavings across a system of connected agents. Uses cone-of-influence abstraction, integer saturation, and symmetry reduction. Raft "at most one leader" proven in 1,001 states.

**Chaos simulation.** `mix vor.simulate` starts real BEAM processes, randomly kills them, partitions connections, delays messages, generates client workload, and checks invariants against live state. Seed-reproducible. No external infrastructure.

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
- No external design verification tooling (TLA+ for small protocols)
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

- **Vor** — coordination: state machines, protocols, invariants, verification, chaos, telemetry
- **Gleam** — data processing when needed, called through type-validated extern boundary

All five examples are fully native Vor. Gleam provides typed library functions for complex data operations when the native expression language isn't sufficient.

## What's working

- Full compiler pipeline to BEAM bytecode
- Three-level verification: compile, check, simulate
- Auto-generated telemetry for gen_server and gen_statem
- Protocol input constraints with `where` clauses
- Sensitive field redaction
- Raft "at most one leader" proven in 1,001 states
- Chaos simulation with kill, partition, delay, workload
- 394+ tests, 9 property-based test suites
- All five examples fully native — zero externs
- Three CRDT types verified native: G-Counter, PN-Counter, OR-Set
- VorDB as first real consumer

---

*vorlang.org  ·  BEAM/OTP  ·  MIT License  ·  394+ tests  ·  Raft proven in 1,001 states*
