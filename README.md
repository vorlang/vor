# Vor

A programming language for the BEAM where the compiler verifies, instruments, and chaos-tests your distributed system.

[vorlang.org](https://vorlang.org)

## Why

AI agents are building distributed systems faster than humans can review them. The BEAM is the right runtime — process isolation, supervision, message passing, distribution. What's missing is a language where the compiler is the reviewer: proving safety, checking protocols, generating telemetry, and stress-testing recovery — all from the same source file.

Vor is that language. One file declares agents, protocols, invariants, and chaos scenarios. Three commands verify it:

```
mix compile        →  proves local safety properties       (milliseconds)
mix vor.check      →  model-checks multi-agent invariants  (seconds)
mix vor.simulate   →  chaos-tests real BEAM processes      (minutes)
```

The compiled binary is pre-instrumented with telemetry. No separate spec. No separate test infrastructure. No instrumentation code.

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

- `safety` invariant proven at compile time — rejects the program if any state × handler combination violates it
- `where` constraint on `:acquire` — rejects requests with invalid priority before the handler runs
- `sensitive` on `auth_token` — redacted in all telemetry events
- `liveness` invariant monitored at runtime — auto-recovers via the resilience handler
- Every state transition, message received, and message emitted generates telemetry automatically
- The compiled binary is a standard OTP gen_statem

## Multi-agent model checking

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
✓ Proven (1001 states, depth 10)
```

## Chaos simulation

```bash
mix vor.simulate --partition --delay --workload 10 --duration 30000
```

Starts real BEAM processes, injects real failures, checks invariants against live state:

- **Kill injection** — randomly kills agent processes, supervisors restart them
- **Network partitions** — proxy processes intercept and drop messages between partitioned groups
- **Message delays** — proxy holds messages for configurable durations
- **Workload generation** — sends client messages matching `accepts` declarations at configurable rates
- **Invariant checking** — periodically queries live agent state and evaluates system invariants
- **Seed reproducibility** — replay any run with `--seed N`

No Chaos Monkey. No Toxiproxy. No Docker. The BEAM provides all the failure injection primitives as function calls.

## Auto-generated telemetry

Every compiled Vor agent emits telemetry for every observable event. Zero instrumentation code.

| Event | Metadata |
|---|---|
| `[:vor, :agent, :start]` | agent name, type (gen_server/gen_statem) |
| `[:vor, :message, :received]` | agent, message tag, current state |
| `[:vor, :transition]` | agent, field, from, to (sensitive fields redacted) |
| `[:vor, :message, :emitted]` | agent, message tag |
| `[:vor, :constraint, :violated]` | agent, message tag, constraint description |

Attach any `:telemetry` backend (Prometheus, StatsD, console logger) and every agent is observable. The compiler knows the program's complete behavioral structure — the telemetry reflects it.

## What's working

**Three-level verification pyramid:**
- Compile-time safety invariants proven by exhaustive state graph traversal
- Multi-agent model checking with cone-of-influence abstraction, integer saturation, symmetry reduction
- Chaos simulation with kill, partition, delay, workload on real BEAM processes

**Language features:**
- Parameterized agents, init handlers, periodic timers (`every`)
- Protocol input constraints with `where` clauses — invalid messages rejected before handlers run
- Sensitive field annotations — redacted in telemetry
- Native map operations (get, put, merge, has, delete, size, sum) with merge strategies
- Native list operations (head, tail, append, prepend, length, empty)
- Auto-generated telemetry for transitions, messages, and lifecycle
- Gleam extern support with compile-time type boundary validation
- Bidirectional relations with compile-time equation inversion

**Testing:**
- 394+ tests, 9 property-based test suites, zero compiler warnings
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

## Background

- [One-pager](docs/onepager.md) — technical overview
- [Paradigm comparison](docs/comparison.md) — what Vor eliminates vs. the typical stack
- [Developer guide](docs/developer-guide.md) — internal compiler reference
- [Tutorial](docs/vor-tutorial.md) — step-by-step from Echo agent to multi-agent pipeline

## License

MIT
