# Vor

A programming language for the BEAM designed as a compilation target for AI coding agents — with verified state machines, protocol checking, chaos testing, and compiler-generated telemetry.

[vorlang.org](https://vorlang.org)

## Why

AI agents are writing more and more code, and they'll inevitably build distributed systems. The code is being produced faster than humans can review it. We need compilers that catch what human review would miss.

The BEAM gives you process isolation, supervision, message passing, and distribution — eliminating data races, buffer overflows, and manual thread management. What it doesn't give you is verification that your state machines are complete, your protocols are compatible, or your system recovers correctly from failures. Most distributed systems discover these bugs in production.

Vor adds the verification layer. You declare state machines, message protocols, safety invariants, and input constraints in a single source file. The compiler proves what it can, the model checker explores message interleavings, and the chaos simulator stress-tests real processes under failure:

```
mix compile        →  proves local safety properties           (milliseconds)
mix vor.check      →  model-checks multi-agent invariants      (seconds)
mix vor.simulate   →  chaos-tests real BEAM processes          (minutes)
```

An AI agent writes one file. Three commands verify it. The compiled binary is a standard OTP gen_server or gen_statem — pre-instrumented with telemetry, no separate spec, no instrumentation code.

## Example

A distributed lock with a proven safety invariant, protocol constraints, and sensitive field handling ([full source](examples/lock.vor)):

```vor
agent LockManager(lock_timeout_ms: integer) do
  state phase: :free | :held
  state holder: atom
  state wait_queue: list
  state auth_token: binary sensitive

  protocol do
    accepts {:acquire, client: atom, priority: integer} where priority >= 1 and priority <= 10
    accepts {:release, client: atom}
    emits {:grant, client: atom}
    emits {:queued, position: integer}
    emits {:ok}
  end

  on {:acquire, client: C, priority: P} when phase == :free do
    transition phase: :held
    transition holder: C
    emit {:grant, client: C}
  end

  on {:acquire, client: C, priority: P} when phase == :held do
    transition wait_queue: list_append(wait_queue, C)
    qlen = list_length(wait_queue)
    emit {:queued, position: qlen}
  end

  on {:release, client: C} when phase == :held do
    if list_empty(wait_queue) == :true do
      transition phase: :free
      transition holder: :nil
      emit {:ok}
    else
      next_client = list_head(wait_queue)
      transition wait_queue: list_tail(wait_queue)
      transition holder: next_client
      emit {:ok}
    end
  end

  safety "no grant when held" proven do
    never(phase == :held and emitted({:grant, _}))
  end

  liveness "lock released eventually" monitored(within: lock_timeout_ms) do
    always(phase == :held implies eventually(phase != :held))
  end

  resilience do
    on_invariant_violation("lock released eventually") ->
      transition phase: :free
      transition holder: :nil
  end
end
```

What the compiler does with this:

- The `safety` invariant is proven at compile time — the program is rejected if any reachable state violates it
- The `where` constraint rejects messages with invalid priority before the handler runs
- The `sensitive` annotation redacts `auth_token` in all telemetry events
- The `liveness` invariant is monitored at runtime with automatic recovery; `liveness ... proven` is verified at compile time via reachability analysis
- Every state transition and message generates telemetry automatically
- The compiled binary is a standard OTP gen_statem

## Multi-agent model checking

Wire agents together in a system block and `mix vor.check` explores all message interleavings within configured bounds:

```vor
system RaftCluster do
  agent :n1, RaftNode(node_id: :n1, cluster_size: 3)
  agent :n2, RaftNode(node_id: :n2, cluster_size: 3)
  agent :n3, RaftNode(node_id: :n3, cluster_size: 3)

  connect :n1 -> :n2
  connect :n1 -> :n3
  connect :n2 -> :n1
  connect :n2 -> :n3
  connect :n3 -> :n1
  connect :n3 -> :n2

  safety "at most one leader" proven do
    never(count(agents where role == :leader) > 1)
  end
end
```

```
$ mix vor.check
Tracked fields:    current_term, role, vote_count
Abstracted fields: commit_index, log, voted_for
Integer bound:     3
Max queue:         10
Symmetry:          enabled (3 identical agents, 6× reduction)
✓ Bounded-verified (1001 states, depth 10)
```

The model checker uses cone-of-influence abstraction, integer saturation, and symmetry reduction. Same code that runs in production. The result is bounded-verified — exhaustive within configured bounds, not an unconditional proof.

## Chaos testing

Chaos testing complements verification by exercising real compiled code under failure — it catches implementation bugs, timing issues, and recovery failures that the model checker can't reach.

Declare a chaos scenario inline:

```vor
system RaftCluster do
  agent :n1, RaftNode(node_id: :n1, cluster_size: 3)
  agent :n2, RaftNode(node_id: :n2, cluster_size: 3)
  agent :n3, RaftNode(node_id: :n3, cluster_size: 3)

  connect :n1 -> :n2
  connect :n1 -> :n3
  connect :n2 -> :n1
  connect :n2 -> :n3
  connect :n3 -> :n1
  connect :n3 -> :n2

  safety "at most one leader" proven do
    never(count(agents where role == :leader) > 1)
  end

  chaos do
    duration 60s
    seed 42
    kill every: 5..15s
    partition duration: 1..5s
    delay by: 50..200ms
    workload rate: 10
    check every: 500ms
  end
end
```

```bash
mix vor.simulate
```

Or configure entirely from the CLI:

```bash
mix vor.simulate --partition --delay --workload 10 --duration 30000 --seed 42
```

Starts real BEAM processes, injects real failures, checks invariants against live state:

- **Kill injection** — randomly kills agent processes, supervisors restart them
- **Network partitions** — proxy processes intercept and drop messages between partitioned groups
- **Message delays** — proxy holds messages for configurable durations
- **Workload generation** — sends client messages matching `accepts` declarations at configurable rates
- **Invariant checking** — periodically queries live agent state and evaluates system invariants
- **Seed reproducibility** — replay any run with `--seed N`
- **Declarative config** — `chaos do ... end` block in the system, CLI flags override file config

For BEAM-native systems, no external chaos infrastructure is needed — the BEAM provides process kill, message interception, and state querying as function calls.

## Auto-generated telemetry

The compiler knows every state field, message type, transition, and handler. It generates telemetry calls in the compiled bytecode — no instrumentation code in the source file.

| Event | Metadata |
|---|---|
| `[:vor, :agent, :start]` | agent name, type (gen_server/gen_statem) |
| `[:vor, :message, :received]` | agent, message tag, current state |
| `[:vor, :transition]` | agent, field, from, to (sensitive fields redacted) |
| `[:vor, :message, :emitted]` | agent, message tag |
| `[:vor, :constraint, :violated]` | agent, message tag, constraint description |
| `[:vor, :backpressure, :rejected]` | agent, message tag, queue length, limit |

Attach any `:telemetry` backend (Prometheus, StatsD, console logger) and every agent is observable. You still need a metrics backend (Prometheus/Grafana) to view the data — Vor generates the events, you bring the dashboard.

## What's working

**Verification and testing:**
- Compile-time safety invariants proven by exhaustive state graph traversal
- Compile-time liveness verification — `liveness "..." proven` checks that every obligated state has a reachable path to fulfillment
- Multi-agent bounded model checking with cone-of-influence abstraction, integer saturation, symmetry reduction
- Multi-agent liveness via Tarjan's SCC — detects cycles where progress is permanently blocked
- Chaos testing with kill, partition, delay, workload on real BEAM processes
- Protocol version compatibility checking — `mix vor.compat` detects breaking changes before rolling deploy

**Language features:**
- Parameterized agents, init handlers, periodic timers (`every`)
- Protocol input constraints with `where` clauses — invalid messages rejected before handlers run
- Backpressure declarations — `max_queue` limits with `priority` bypass for health checks
- Sensitive field annotations — redacted in telemetry
- `requires` declarations in system blocks — infrastructure dependencies started before agents during simulation
- Native map operations (get, put, merge, has, delete, size, sum) with merge strategies
- Native list operations (head, tail, append, prepend, length, empty)
- Auto-generated telemetry for transitions, messages, lifecycle, and backpressure events
- Gleam extern support with compile-time type boundary validation
- Bidirectional relations with compile-time equation inversion

**Testing:**
- 434+ tests, 9 property-based test suites, zero compiler warnings
- All five examples fully native — zero externs:
  - Distributed lock: proven safety, liveness recovery, protocol constraints
  - Circuit breaker: proven safety, liveness recovery
  - Raft consensus: model-checked leader uniqueness in 1,001 states
  - G-Counter CRDT: native map ops, periodic gossip
  - Rate limiter: native map ops, per-client tracking

## Try it

```bash
git clone git@github.com:vorlang/vor.git
cd vor
mix deps.get
mix test
```

Run the lock interactively:

```
iex -S mix

{:ok, r} = Vor.compile_and_load(File.read!("examples/lock.vor"))
{:ok, pid} = :gen_statem.start_link(r.module, [lock_timeout_ms: 5000], [])
:gen_statem.call(pid, {:acquire, %{client: :alice, priority: 5}})
# => {:grant, %{client: :alice}}
```

Model-check the Raft cluster:

```bash
mix vor.check
```

Chaos-test with partitions and workload:

```bash
mix vor.simulate --partition --delay --workload 10
```

## Built with Vor

- [VorDB](https://github.com/vorlang/vordb) — a CRDT-based distributed database, the first real consumer driving Vor's language features through practical use

## Related projects

- [Tyn](https://github.com/tyn-os/kernel) — a minimal Rust microkernel that runs the BEAM on bare metal (no Linux). Vor + Tyn is the long-term vision: verified distributed systems on a purpose-built kernel.

## Background

- [One-pager](docs/onepager.md) — technical overview
- [Paradigm comparison](docs/comparison.md) — how Vor compares to the typical stack
- [Developer guide](docs/developer-guide.md) — internal compiler reference
- [Tutorial](docs/vor-tutorial.md) — step-by-step from Echo agent to multi-agent pipeline

## License

MIT
