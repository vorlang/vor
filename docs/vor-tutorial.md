# Building a rate limiter in Vor

A step-by-step tutorial that introduces Vor's constructs by building a working rate limiter from scratch. Each step compiles and runs. By the end, you'll have an agent with state, parameters, relations, invariants, and extern calls — the full Vor toolkit.

## Prerequisites

```bash
git clone git@github.com:vorlang/vor.git
cd vor
mix deps.get
mix test   # should pass
```

You'll work in `iex -S mix` throughout this tutorial.

---

## Step 1: The simplest agent — Echo

Every Vor program is an **agent** — a process that receives messages and responds. The simplest possible agent echoes back whatever you send it.

Create a file called `tutorial/step1.vor`:

```vor
agent Echo do
  protocol do
    accepts {:ping, payload: term}
    emits {:pong, payload: term}
  end

  on {:ping, payload: P} do
    emit {:pong, payload: P}
  end
end
```

Four constructs in six lines:

- **`agent`** declares a process. It compiles to an OTP `gen_server` on the BEAM — the same thing you'd get from writing a GenServer module in Elixir.
- **`protocol`** declares the message contract: what the agent accepts and what it emits. The compiler checks every handler against this contract.
- **`on`** is a message handler. The pattern `{:ping, payload: P}` matches incoming messages and binds the variable `P`.
- **`emit`** sends a response. The compiler verifies that `{:pong, payload: P}` matches something in the protocol's `emits` list.

Try it:

```elixir
iex> {:ok, mod} = Vor.Compiler.compile(File.read!("tutorial/step1.vor"))
iex> {:ok, pid} = GenServer.start_link(mod, [])
iex> GenServer.call(pid, {:ping, %{payload: "hello"}})
{:pong, %{payload: "hello"}}
```

That response came from a compiled BEAM module. The Vor source was lexed, parsed, lowered to an intermediate representation, translated to Erlang abstract format, compiled to BEAM bytecode by `:compile.forms/2`, and loaded into the running VM. At runtime, the Echo agent is indistinguishable from a hand-written GenServer.

**What the compiler checked:** The `emit {:pong, payload: P}` matches the protocol's `emits {:pong, payload: term}`. If you changed the emit to `{:wrong, payload: P}`, the compiler would reject it — `:wrong` isn't in the protocol.

---

## Step 2: Adding state

A rate limiter needs to count requests. Vor agents can have **state fields** — mutable data that handlers can read and update.

Create `tutorial/step2.vor`:

```vor
agent Counter do
  state count: integer

  protocol do
    accepts {:increment}
    accepts {:get}
    emits {:ok}
    emits {:count, value: integer}
  end

  on {:increment} do
    transition count: count + 1
    emit {:ok}
  end

  on {:get} do
    emit {:count, value: count}
  end
end
```

New constructs:

- **`state count: integer`** declares a mutable field. It starts at 0 (the default for integers). The field lives in the GenServer state map alongside any parameters.
- **`transition count: count + 1`** updates the field. You can use arithmetic expressions. Multiple transitions in one handler are collapsed into a single state update.

Try it:

```elixir
iex> {:ok, mod} = Vor.Compiler.compile(File.read!("tutorial/step2.vor"))
iex> {:ok, pid} = GenServer.start_link(mod, [])
iex> GenServer.cast(pid, {:increment})
iex> GenServer.cast(pid, {:increment})
iex> GenServer.cast(pid, {:increment})
iex> GenServer.call(pid, {:get})
{:count, %{value: 3}}
```

Notice that `{:increment}` uses `cast` (fire-and-forget) while `{:get}` uses `call` (wait for response). Handlers that `emit` are call handlers. Handlers that don't emit (or use `noop`) are cast handlers. The compiler generates the right OTP callback for each.

**State vs parameters:** State fields change over time — `count` increases with each request. Parameters (which we'll add next) are set once at startup and never change. Vor keeps these separate because they serve different purposes.

---

## Step 3: Parameters

A rate limiter with a hardcoded limit isn't very useful. **Parameterized agents** accept configuration at startup.

Create `tutorial/step3.vor`:

```vor
agent BoundedCounter(max: integer) do
  state count: integer

  protocol do
    accepts {:increment}
    accepts {:get}
    emits {:ok, remaining: integer}
    emits {:full}
    emits {:count, value: integer}
  end

  on {:increment} do
    if count < max do
      transition count: count + 1
      emit {:ok, remaining: max - count - 1}
    else
      emit {:full}
    end
  end

  on {:get} do
    emit {:count, value: count}
  end
end
```

New constructs:

- **`agent BoundedCounter(max: integer)`** declares a parameter. Parameters are passed as a keyword list when starting the agent and are available everywhere in the agent — handlers, relations, invariants.
- **`if/else`** is conditional logic in handler bodies. The compiler checks that every code path through an if/else emits a response (for call handlers). A missing `else` when the `if` body contains an emit is a compile error.

Try it:

```elixir
iex> {:ok, mod} = Vor.Compiler.compile(File.read!("tutorial/step3.vor"))
iex> {:ok, pid} = GenServer.start_link(mod, [max: 3])
iex> GenServer.call(pid, {:increment})
{:ok, %{remaining: 2}}
iex> GenServer.call(pid, {:increment})
{:ok, %{remaining: 1}}
iex> GenServer.call(pid, {:increment})
{:ok, %{remaining: 0}}
iex> GenServer.call(pid, {:increment})
{:full}
```

Start another instance with a different limit:

```elixir
iex> {:ok, pid2} = GenServer.start_link(mod, [max: 100])
iex> GenServer.call(pid2, {:increment})
{:ok, %{remaining: 99}}
```

Same compiled module, different configuration. Parameters map directly to OTP init args.

---

## Step 4: Relations

A rate limiter often has different limits for different client tiers. You could use nested if/else to check the tier, but Vor has a better abstraction: **relations**.

Create `tutorial/step4.vor`:

```vor
agent TieredCounter(default_max: integer) do
  state count: integer

  relation tier_limit(client: atom, max_requests: integer) do
    fact(client: :free, max_requests: 10)
    fact(client: :pro, max_requests: 100)
    fact(client: :enterprise, max_requests: 1000)
  end

  protocol do
    accepts {:request, client: atom}
    accepts {:get_limit, client: atom}
    emits {:ok, remaining: integer}
    emits {:rejected}
    emits {:limit, max: integer}
  end

  on {:request, client: C} do
    solve tier_limit(client: C, max_requests: Max) do
      if count < Max do
        transition count: count + 1
        emit {:ok, remaining: Max - count - 1}
      else
        emit {:rejected}
      end
    end
  end

  on {:get_limit, client: C} do
    solve tier_limit(client: C, max_requests: Max) do
      emit {:limit, max: Max}
    end
  end
end
```

New constructs:

- **`relation`** declares a bidirectional knowledge structure. It has named fields and a set of facts. Unlike a lookup table, relations can be queried from any direction.
- **`fact`** populates the relation with a concrete row of data.
- **`solve`** queries the relation. You provide some fields (the bound variables) and the solver fills in the rest. Here, `client: C` is bound from the message pattern, and the solver fills in `max_requests: Max`.

Try it:

```elixir
iex> {:ok, mod} = Vor.Compiler.compile(File.read!("tutorial/step4.vor"))
iex> {:ok, pid} = GenServer.start_link(mod, [default_max: 10])
iex> GenServer.call(pid, {:get_limit, %{client: :pro}})
{:limit, %{max: 100}}
iex> GenServer.call(pid, {:get_limit, %{client: :enterprise}})
{:limit, %{max: 1000}}
```

**Bidirectional queries:** Relations aren't just forward lookups. You can also query them in reverse:

```vor
on {:who_has_limit, max_requests: M} do
  solve tier_limit(client: C, max_requests: M) do
    emit {:client, name: C}
  end
end
```

Provide `max_requests`, get back `client`. Same relation, different direction. In Elixir, you'd need to write a separate function for each query direction. In Vor, one relation handles all directions.

**Equation-based relations:** Relations can also use equations instead of facts:

```vor
relation temperature(celsius: integer, fahrenheit: integer) do
  fahrenheit = celsius * 9 / 5 + 32
end
```

Query with celsius to get fahrenheit, or with fahrenheit to get celsius. The compiler inverts the equation at compile time — at runtime it's just arithmetic, no solver overhead.

---

## Step 5: Safety invariants

This is where Vor diverges from every other BEAM language. An **invariant** is a property that must always hold. The compiler verifies it.

To demonstrate invariants, we need a **state machine** — an agent with named states and transitions between them. When an agent declares an enum state field, it compiles to a gen_statem instead of a gen_server.

Create `tutorial/step5.vor`:

```vor
agent Gate do
  state phase: :closed | :open

  protocol do
    accepts {:open_gate}
    accepts {:close_gate}
    accepts {:enter}
    emits {:ok}
    emits {:denied}
  end

  on {:open_gate} when phase == :closed do
    transition phase: :open
    emit {:ok}
  end

  on {:close_gate} when phase == :open do
    transition phase: :closed
    emit {:ok}
  end

  on {:enter} when phase == :open do
    emit {:ok}
  end

  on {:enter} when phase == :closed do
    emit {:denied}
  end

  safety "no entry when closed" proven do
    never(phase == :closed and emitted({:ok, _}))
  end
end
```

Wait — that invariant will fail. The `{:open_gate}` handler emits `{:ok}` when `phase == :closed`. The invariant says "never emit {:ok} when closed." Let's fix the invariant to be more specific about what we actually mean — no entry (not no gate operation) when closed:

Actually, this is a good teaching moment. Let's see what happens:

```elixir
iex> Vor.Compiler.compile(File.read!("tutorial/step5.vor"))
{:error, %{type: :invariant_violation, ...}}
```

The compiler catches it. The safety invariant says `never(phase == :closed and emitted({:ok, _}))` but the `{:open_gate}` handler emits `{:ok}` while in the `:closed` state. The compiler walked the state graph, found the violating path, and rejected the program.

Fix it by using distinct emit tags:

```vor
agent Gate do
  state phase: :closed | :open

  protocol do
    accepts {:open_gate}
    accepts {:close_gate}
    accepts {:enter}
    emits {:opened}
    emits {:closed_gate}
    emits {:allowed}
    emits {:denied}
  end

  on {:open_gate} when phase == :closed do
    transition phase: :open
    emit {:opened}
  end

  on {:close_gate} when phase == :open do
    transition phase: :closed
    emit {:closed_gate}
  end

  on {:enter} when phase == :open do
    emit {:allowed}
  end

  on {:enter} when phase == :closed do
    emit {:denied}
  end

  safety "no entry when closed" proven do
    never(phase == :closed and emitted({:allowed, _}))
  end
end
```

Now it compiles:

```elixir
iex> {:ok, mod} = Vor.Compiler.compile(File.read!("tutorial/step5_fixed.vor"))
iex> {:ok, pid} = :gen_statem.start_link(mod, [], [])
iex> :gen_statem.call(pid, {:enter})
{:denied}
iex> :gen_statem.call(pid, {:open_gate})
{:opened}
iex> :gen_statem.call(pid, {:enter})
{:allowed}
```

New constructs:

- **`state phase: :closed | :open`** declares an enum state. This makes the agent compile to gen_statem instead of gen_server. The compiler knows the complete set of valid states.
- **`when phase == :closed`** is a guard on a handler. It restricts when the handler can fire based on the current state.
- **`transition phase: :open`** changes the state. The compiler records this as an edge in the transition graph.
- **`safety "name" proven do ... end`** declares a safety invariant. The `proven` tag means the compiler must verify it at compile time by walking the state graph. If it can't prove the property, compilation fails.

**What "proven" means:** The compiler built a state graph — two states (`:closed`, `:open`), transitions between them, and what each state can emit. Then it checked: "is there any state where `phase == :closed` AND the handler emits `{:allowed, _}`?" It walked every path and confirmed there isn't. That's a proof by exhaustive graph traversal — not testing, not fuzzing, but checking every possibility.

**What the compiler sees:**

```
$ mix vor.graph tutorial/step5_fixed.vor

Gate state graph
════════════════

States: closed (initial), open

Transitions:
  closed → open     when {:open_gate}
  open → closed     when {:close_gate}

Emits by state:
  closed:  {:opened}, {:denied}
  open:    {:closed_gate}, {:allowed}
```

---

## Step 6: Liveness monitoring

Safety invariants say "bad things never happen." **Liveness invariants** say "good things eventually happen." They can't be proven at compile time (they depend on timing and external events), so they're enforced at runtime.

Create `tutorial/step6.vor`:

```vor
agent TimedGate(auto_close_ms: integer) do
  state phase: :closed | :open

  protocol do
    accepts {:open_gate}
    accepts {:enter}
    emits {:opened}
    emits {:allowed}
    emits {:denied}
    emits {:auto_closed}
  end

  on {:open_gate} when phase == :closed do
    transition phase: :open
    emit {:opened}
  end

  on {:enter} when phase == :open do
    emit {:allowed}
  end

  on {:enter} when phase == :closed do
    emit {:denied}
  end

  liveness "gate closes eventually" monitored(within: auto_close_ms) do
    always(phase == :open implies eventually(phase != :open))
  end

  resilience do
    on_invariant_violation("gate closes eventually") ->
      transition phase: :closed
  end

  safety "no entry when closed" proven do
    never(phase == :closed and emitted({:allowed, _}))
  end
end
```

New constructs:

- **`liveness "name" monitored(within: duration)`** declares a runtime invariant. If the agent stays in `:open` for longer than `auto_close_ms`, the liveness monitor triggers.
- **`resilience`** declares what happens when an invariant is violated. Here, the gate automatically closes. The resilience handler is generated as a regular handler clause — the safety verifier checks it too.

Try it:

```elixir
iex> {:ok, mod} = Vor.Compiler.compile(File.read!("tutorial/step6.vor"))
iex> {:ok, pid} = :gen_statem.start_link(mod, [auto_close_ms: 500], [])
iex> :gen_statem.call(pid, {:open_gate})
{:opened}
iex> # Wait for auto-close...
iex> Process.sleep(700)
iex> :gen_statem.call(pid, {:enter})
{:denied}
```

The gate opened, nobody closed it within 500ms, so the liveness monitor fired the resilience handler and closed it automatically. No stuck-open gates. No process consuming memory forever in a state it was never supposed to stay in.

**How it works under the hood:** The compiler generates a gen_statem state timeout. When the agent enters `:open`, it sets a timeout of `auto_close_ms`. If the state changes before the timeout fires (someone manually closes the gate), gen_statem automatically cancels it. If the timeout fires, the resilience handler executes. Pure OTP mechanics, generated from the spec.

---

## Step 7: Extern calls

Vor handles protocol logic, state machines, and verification. For everything else — database access, HTTP calls, string manipulation, list operations — you call Elixir functions through **extern declarations**.

Create a helper module first. In `lib/vor/examples/tutorial_helpers.ex`:

```elixir
defmodule Vor.Examples.TutorialHelpers do
  @table :tutorial_rate_counts

  def start do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end
    :ok
  end

  def increment(client, window_ms) do
    start()
    now = System.monotonic_time(:millisecond)
    key = {client, div(now, window_ms)}
    :ets.update_counter(@table, key, {2, 1}, {key, 0})
  end

  def reset do
    if :ets.whereis(@table) != :undefined do
      :ets.delete_all_objects(@table)
    end
    :ok
  end
end
```

Now create `tutorial/step7.vor`:

```vor
agent RateLimiter(max_requests: integer, window_ms: integer) do
  extern do
    Vor.Examples.TutorialHelpers.increment(client: binary, window_ms: integer) :: integer
  end

  protocol do
    accepts {:request, client: binary}
    emits {:ok, remaining: integer}
    emits {:rejected}
  end

  on {:request, client: C} do
    current = Vor.Examples.TutorialHelpers.increment(client: C, window_ms: window_ms)
    if current <= max_requests do
      emit {:ok, remaining: max_requests - current}
    else
      emit {:rejected}
    end
  end
end
```

New constructs:

- **`extern do ... end`** declares external Elixir/Erlang functions the agent uses. Each declaration includes the module, function name, argument types, and return type.
- **Extern calls in handlers** look like regular function calls. The variable `current` is bound to the return value.

Try it:

```elixir
iex> Vor.Examples.TutorialHelpers.reset()
iex> {:ok, mod} = Vor.Compiler.compile(File.read!("tutorial/step7.vor"))
iex> {:ok, pid} = GenServer.start_link(mod, [max_requests: 3, window_ms: 60_000])
iex> GenServer.call(pid, {:request, %{client: "alice"}})
{:ok, %{remaining: 2}}
iex> GenServer.call(pid, {:request, %{client: "alice"}})
{:ok, %{remaining: 1}}
iex> GenServer.call(pid, {:request, %{client: "alice"}})
{:ok, %{remaining: 0}}
iex> GenServer.call(pid, {:request, %{client: "alice"}})
{:rejected}
iex> GenServer.call(pid, {:request, %{client: "bob"}})
{:ok, %{remaining: 2}}
```

**Trust model:** Extern calls are untrusted by default. The compiler wraps each call in a try/catch so that a crash in Elixir code doesn't silently kill the Vor agent. If a `proven` invariant depends on an extern call's return value, the compiler warns you — it can't verify properties about code it can't see. Use `monitored` invariants for properties that involve extern results.

---

## Step 8: Multi-agent systems

Real systems have multiple agents communicating. Vor's **system blocks** wire agents together with compile-time protocol checking.

Create `tutorial/step8.vor`:

```vor
agent Producer do
  protocol do
    accepts {:produce, item: integer}
    sends {:data, item: integer}
    emits {:sent}
  end

  on {:produce, item: I} do
    send :consumer {:data, item: I}
    emit {:sent}
  end
end

agent Consumer do
  state total: integer

  protocol do
    accepts {:data, item: integer}
    accepts {:get_total}
    emits {:total, value: integer}
  end

  on {:data, item: I} do
    transition total: total + I
  end

  on {:get_total} do
    emit {:total, value: total}
  end
end

system Pipeline do
  agent :producer, Producer()
  agent :consumer, Consumer()
  connect :producer -> :consumer
end
```

New constructs:

- **`sends`** in the protocol declares messages an agent forwards to other agents. Different from `emits` which replies to the caller. `sends` are asynchronous; `emits` are synchronous.
- **`send :consumer {:data, item: I}`** forwards a message to a named agent via the system's Registry.
- **`system`** declares a multi-agent topology. It names each agent instance and declares connections.
- **`connect :producer -> :consumer`** wires agents together. The compiler verifies that Producer's `sends` match Consumer's `accepts` — if the field names or message tags don't match, compilation fails.

Try it:

```elixir
iex> {:ok, modules} = Vor.Compiler.compile_system(File.read!("tutorial/step8.vor"))
iex> {:ok, sup_pid} = modules.system.start_link()
iex> [{producer_pid, _}] = Registry.lookup(Pipeline.Registry, :producer)
iex> GenServer.call(producer_pid, {:produce, %{item: 10}})
{:sent}
iex> GenServer.call(producer_pid, {:produce, %{item: 20}})
{:sent}
iex> Process.sleep(50)  # wait for async messages
iex> [{consumer_pid, _}] = Registry.lookup(Pipeline.Registry, :consumer)
iex> GenServer.call(consumer_pid, {:get_total})
{:total, %{value: 30}}
iex> Supervisor.stop(sup_pid)
```

**What the compiler checked:** Producer sends `{:data, item: integer}`. Consumer accepts `{:data, item: integer}`. The tags match, the field names match. If you changed Producer to send `{:data, value: integer}` (different field name), the compiler would reject the system — protocol mismatch.

**Broadcast:** Use `broadcast {:msg, ...}` instead of `send :target {:msg, ...}` to send to all connected agents at once. Same protocol checking, but the message goes to every outbound connection.

---

## What you've built

In eight steps, you've used every core Vor construct:

| Construct | What it does | Step |
|---|---|---|
| `agent` | Declares a process (gen_server or gen_statem) | 1 |
| `protocol` | Message contract (accepts, emits, sends) | 1 |
| `on` / `emit` | Handler with response | 1 |
| `state` (non-enum) | Mutable data field with transitions | 2 |
| Parameters | Immutable config at startup | 3 |
| `relation` / `solve` | Bidirectional knowledge queries | 4 |
| `state` (enum) | State machine with verified transitions | 5 |
| `safety` / `proven` | Compile-time verified invariants | 5 |
| `liveness` / `monitored` | Runtime invariant monitoring | 6 |
| `resilience` | Failure recovery declarations | 6 |
| `extern` | Calling Elixir/Erlang functions | 7 |
| `system` / `send` / `broadcast` | Multi-agent communication | 8 |

At runtime, every Vor agent is a standard OTP process. The BEAM doesn't know or care that it came from a `.vor` file. You get all of OTP's concurrency, fault tolerance, and distribution for free. What Vor adds is the verification layer above — the compiler understands what your program means, not just how it runs.

---

## Next steps

- Read `examples/rate_limiter.vor` — the full rate limiter with ETS backing
- Read `examples/circuit_breaker.vor` — a verified state machine with safety invariants
- Read `examples/raft.vor` — Raft consensus protocol with multi-agent communication
- Run `mix vor.graph examples/circuit_breaker.vor` to see the state machine visualization
- Run `mix test` to see all 164+ tests pass
- Read the [manifesto](https://vorlang.org) for the design philosophy
- Read `docs/developer-guide.md` for the full language reference
