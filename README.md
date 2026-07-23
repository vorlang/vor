# Vor

A programming language for the BEAM designed as a compilation target for AI coding agents — with verified state machines, protocol checking, chaos testing, and compiler-generated telemetry.

[vorlang.org](https://vorlang.org)

## Why

AI agents are writing more and more code, and they'll inevitably build distributed systems. The code is being produced faster than humans can review it. We need compilers that catch what human review would miss.

The BEAM gives you process isolation, supervision, message passing, and distribution — eliminating data races, buffer overflows, and manual thread management. What it doesn't give you is verification that your state machines are complete, your protocols are compatible, or your system recovers correctly from failures. Most distributed systems discover these bugs in production.

Vor adds a checking layer. You declare state machines, message protocols, safety invariants, and input constraints in a single source file, and three tiers of checking all read that same declaration:

```
mix compile        →  proves local safety properties           (milliseconds)
mix vor.check      →  finds multi-agent counterexamples        (seconds)
mix vor.simulate   →  chaos-tests real BEAM processes          (minutes)
```

One file. Three tiers. The compiled binary is a standard OTP `gen_server` or `gen_statem` — pre-instrumented with telemetry, no separate spec, no instrumentation code.

## The part that matters: Vor tells you when it checked nothing

A checker that returns "✓ Proven" over a state space where the property's subject can't exist is *sound*, *honest about its bounds*, and **useless** — and most tools can't tell the difference. Vor can, because it knows what your program *declared* it should do and compares that against what was actually reached.

Every invariant reports two axes:

| Axis | Values | Meaning |
|---|---|---|
| **Strength** | `proven` / `bounded` / `monitored` | How strong is the evidence |
| **Relevance** | `substantive` / `vacuous` / `unexercised` | Did the check engage with anything |

```
✓ Proven    "no grant when held"    substantive   (subject true in 2 of 4 states)
⚠ Bounded   "at most one leader"    VACUOUS       (subject `role == :leader` never true)
⚠ Monitored "breaker recovers"      UNEXERCISED   (`half_open` never reached)
```

A `proven`-tier invariant whose subject is unreachable is a **compile error**, not a warning — the same fail-closed principle as the extern boundary: *never claim to have verified a property you never exercised.*

The simulator carries the same discipline. A run whose fault injection died partway through reports **`UNDER-TESTED`**, never a clean pass. Both tiers also report declared-vs-observed coverage: which declared states, handlers, and message types were actually reached.

This is what a language buys that a library can't. Detecting that a check engaged with nothing requires a machine-readable declaration of what "something" would have been.

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

- The `safety` invariant is proven at compile time — the program is rejected if any reachable state violates it, **or if the invariant turns out to be vacuous**
- The `where` constraint rejects messages with invalid priority before the handler runs
- The `sensitive` annotation redacts `auth_token` in all telemetry events
- The `liveness` invariant is monitored at runtime with automatic recovery; `liveness ... proven` is verified at compile time via reachability analysis
- Every state transition and message generates telemetry automatically
- The compiled binary is a standard OTP `gen_statem`

## Multi-agent checking

Wire agents together in a system block and `mix vor.check` explores message interleavings within configured bounds:

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

  safety "at most one leader per term" proven do
    never(exists A, B where A.role == :leader and B.role == :leader
                            and A.current_term == B.current_term)
  end
end
```

**`mix vor.check` is a bug-finder first.** Finding a counterexample is fast — often under a second. Exhaustive verification is available too, but only at small bounds: the state space explodes with message-queue depth, and neither symmetry reduction nor partial-order reduction changes that (see [evidence/](evidence/)). It never runs during `mix compile`.

### How the invariant above got that way

The original example declared `never(count(agents where role == :leader) > 1)`. It reported `✓ Proven (1001 states)` — and that result was **vacuous**: the explorer wasn't firing election timeouts, so no node ever became a leader. The property held over a state space in which its subject could not exist.

Once timers fired, the checker found a counterexample in 0.16 s — and it turned out the *invariant itself* was wrong. Raft guarantees one leader **per term**; a stale leader from term 1 legitimately coexists with a term-2 leader until it steps down. The corrected per-term invariant is `proven` and `substantive`.

Two errors — an empty model and a mis-specified property — and the first hid the second. That's why relevance reporting exists. Full account in [evidence/](evidence/) and [KNOWN_ISSUES.md](KNOWN_ISSUES.md).

## Chaos testing

Chaos testing exercises real compiled code under failure — catching implementation bugs, timing issues, and recovery failures the model checker can't reach. It's also structurally immune to vacuity: there's no abstract model to be empty, because real processes either did the thing or didn't.

Declare a scenario inline:

```vor
chaos do
  duration 60s
  seed 42
  kill every: 5..15s
  partition duration: 1..5s
  delay by: 50..200ms
  workload rate: 10
  check every: 500ms
end
```

```bash
mix vor.simulate
mix vor.simulate --partition --delay --workload 10 --duration 30000 --seed 42
```

Starts real BEAM processes, injects real failures, checks invariants against live state:

- **Kill injection** — kills agent processes; supervisors restart them
- **Network partitions** — proxy processes intercept and drop messages between groups
- **Message delays** — proxies hold messages for configurable durations
- **Workload generation** — sends client messages matching `accepts` declarations
- **Invariant checking** — periodically queries live state via `:sys.get_state`
- **Coverage and integrity** — reports declared-vs-observed coverage, and flags a run as `UNDER-TESTED` if the harness degraded
- **Seeded inputs** — fault schedule and workload are deterministic in the seed

On **seed reproducibility**: all *inputs* are seeded, so a given seed produces the same fault schedule and workload. The BEAM's scheduler interleaving and real OTP timer firing are **not** controlled, so replay is highly reliable but not byte-for-byte deterministic. Measured reproduction of a known Raft violation: 100% on an idle machine, degrading under heavy load. See [evidence/](evidence/).

No external chaos infrastructure is needed — the BEAM provides process kill, message interception, and state querying as function calls.

## Auto-generated telemetry

The compiler knows every state field, message type, transition, and handler, and generates telemetry calls in the compiled bytecode — no instrumentation code in the source.

| Event | Metadata |
|---|---|
| `[:vor, :agent, :start]` | agent name, type (gen_server/gen_statem) |
| `[:vor, :message, :received]` | agent, message tag, current state |
| `[:vor, :transition]` | agent, field, from, to (sensitive fields redacted) |
| `[:vor, :message, :emitted]` | agent, message tag (every outbound form: `emit`/reply, `send`, `broadcast`) |
| `[:vor, :constraint, :violated]` | agent, message tag, constraint description |
| `[:vor, :backpressure, :rejected]` | agent, message tag, queue length, limit |

Attach any `:telemetry` backend (Prometheus, StatsD, console logger) and every agent is observable. This same stream is what feeds simulation coverage — telemetry generated *from the declaration* is how coverage knows what to look for. Emitted-message events carry the **declared** tag straight from the compiler (not recovered from a runtime reply value), so the coverage "which message types were exercised" axis is exact for `gen_server` and `gen_statem` alike.

## What's working

**Checking:**
- Compile-time safety invariants proven by exhaustive state graph traversal
- Compile-time liveness verification via reachability analysis
- **Vacuity / relevance detection** across both the checker and the simulator; vacuous `proven` invariants are compile errors
- Declared-vs-observed coverage — reached states, handlers, and message types vs. what was declared
- Multi-agent bounded model checking with cone-of-influence abstraction and integer saturation
- Multi-agent liveness via Tarjan's SCC
- Chaos testing with kill, partition, delay, and workload on real BEAM processes, with execution-integrity reporting
- Protocol version compatibility checking — `mix vor.compat` detects breaking changes before rolling deploy
- Queryable spec inventory — `mix vor.surface` (JSON/text)
- Verification posture report — `mix vor.coverage`

**Language features:**
- Parameterized agents, init handlers, periodic timers (`every`)
- Protocol input constraints with `where` clauses
- Default values on `accepts` fields
- Backpressure declarations — `max_queue` with `priority` bypass
- Sensitive field annotations, redacted in telemetry
- `requires` declarations for infrastructure dependencies
- Native map and list operations
- Gleam extern support with compile-time type boundary validation
- Bidirectional relations with compile-time equation inversion

**Examples** (all five fully native, zero externs):

| Example | Status |
|---|---|
| Distributed lock | Proven safety, protocol constraints; substantive |
| Raft consensus | Per-term leader uniqueness proven and substantive; the global variant is a documented war story |
| Circuit breaker | Proven safety; `half_open` is **not reachable in simulation** — the recovery timer is never armed |
| G-Counter CRDT | Native map ops; gossip fires, but map contents abstract to `:unknown`, so convergence is not value-checkable |
| Rate limiter | Native map ops, per-client tracking |

## Limitations

- **Multi-agent exhaustive checking is intractable beyond small bounds.** Interleaving explosion; not a `mix compile`-time operation. Partial-order reduction is sound but buys ~1× on the Raft model (always-enabled broadcasting timers block it).
- **Symmetry reduction is unsound** — the canonicalization is not orbit-exact and can prune real states. Known, filed, deprioritized (it only bought ~2× on an honest model).
- **Map and collection contents abstract to `:unknown`**, so value-level convergence (e.g. G-Counter) is reachable but not checkable.
- **Simulation replay is not byte-for-byte deterministic** — inputs are seeded; scheduler interleaving is not.

Full detail in [KNOWN_ISSUES.md](KNOWN_ISSUES.md); measurements in [evidence/](evidence/).

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
