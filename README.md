# Vor

A programming language for the BEAM with verified state machines, protocol checking, and an embedded model checker for distributed systems.

[vorlang.org](https://vorlang.org)

## Why

The hardest bugs in distributed systems aren't logic errors — they're coordination failures where message ordering produces states nobody anticipated. Design docs drift from code on day one. TLA+ specs sit in a separate repo that nobody updates after launch. The implementation becomes the only source of truth, and it's a source that can't answer "is this correct?"

Vor is a language where you declare what must be true — state machines, message protocols, safety invariants — and the compiler proves those declarations hold. For multi-agent systems, `mix vor.check` model-checks the real code by exploring all message interleavings. One artifact. No separate spec. No drift.

## Example

A distributed lock with a proven safety invariant ([full source](examples/lock.vor)):

```vor
agent LockManager(lock_timeout_ms: integer) do
  state phase: :free | :held
  state holder: atom
  state wait_queue: list

  protocol do
    accepts {:acquire, client: atom}
    accepts {:release, client: atom}
    emits {:grant, client: atom}
    emits {:queued, position: integer}
    emits {:ok}
  end

  on {:acquire, client: C} when phase == :free do
    transition phase: :held
    transition holder: C
    emit {:grant, client: C}
  end

  on {:acquire, client: C} when phase == :held do
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

The `safety` invariant is proven at compile time — the compiler exhaustively walks every reachable state and rejects the program if the property can be violated. The `liveness` invariant is monitored at runtime with automatic recovery.

## Multi-agent model checking

Wire agents together in a system block and `mix vor.check` proves distributed invariants by exploring all message interleavings:

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

The model checker uses cone-of-influence abstraction, integer saturation, and symmetry reduction. Same code that runs in production. No separate spec.

## What's working

**Compiler:**
- Full pipeline: `.vor` source → Lexer → Parser → AST → IR → Verification → Erlang codegen → BEAM binary
- Agents compile to OTP `gen_server` and `gen_statem`
- Compilation under 5ms, single-agent verification under 2ms

**Verification:**
- Compile-time safety invariants proven by exhaustive state graph traversal
- Multi-agent model checking via product state exploration (`mix vor.check`)
- Cone-of-influence abstraction, integer saturation, queue bounding, symmetry reduction
- System-level invariants: `count`, `exists`, `for_all`, cross-agent comparisons, named agent references
- Raft "at most one leader" proven exhaustively in 1,001 states
- Extern proven boundary — proven invariants cannot depend on extern results (compile error)
- Internal type tracking catches guaranteed crashes at compile time
- Runtime liveness monitoring with declared recovery via resilience handlers
- Protocol composition checking across connected agents
- Safety verifier verified by TLA+ specifications

**Language features:**
- Parameterized agents, init handlers, periodic timers (`every`)
- Native map operations (get, put, merge, has, delete, size, sum) with merge strategies (max, min, sum, replace, LWW)
- Native list operations (head, tail, append, prepend, length, empty)
- Bidirectional relations with compile-time equation inversion
- Multi-agent systems with `send`, `broadcast`, Registry-based discovery
- Gleam extern support with compile-time type boundary validation

**Testing:**
- 351+ tests, 9 property-based test suites, zero compiler warnings
- All five examples fully native — zero Elixir externs:
  - Distributed lock: native list ops, proven safety, liveness timeout
  - Circuit breaker: pure state machine, proven safety, liveness recovery
  - Raft consensus: native arithmetic + list ops, model-checked leader uniqueness
  - G-Counter CRDT: native map ops, periodic gossip, zero externs
  - Rate limiter: native map ops, per-client tracking
- Three CRDT types verified native (zero externs): G-Counter, PN-Counter, OR-Set

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
:gen_statem.call(pid, {:acquire, %{client: :alice}})
# => {:grant, %{client: :alice}}
```

Model-check the Raft cluster:

```bash
mix vor.check
```

## Built with Vor

- [VorDB](https://github.com/vorlang/vordb) — a CRDT-based distributed database, the first real consumer driving Vor's language features through practical use

## Background

- [One-pager](docs/onepager.md) — technical overview
- [Paradigm comparison](docs/comparison.md) — how Vor differs from mainstream approaches, verification tools, and other BEAM languages
- [Developer guide](docs/developer-guide.md) — internal compiler reference
- [Tutorial](docs/vor-tutorial.md) — step-by-step from Echo agent to multi-agent pipeline

## License

MIT
