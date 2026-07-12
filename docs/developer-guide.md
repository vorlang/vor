# Vor Developer Guide

Internal compiler reference for contributors and the coding agent.

## Architecture

```
.vor source → Lexer (NimbleParsec) → Parser → AST → IR (Lowering)
    → Analysis/Verification → Erlang codegen → BEAM binary
```

Three verification levels:
```
mix compile        → single-agent safety proofs (ms)
mix vor.check      → multi-agent model checking (seconds)
mix vor.simulate   → chaos testing on real BEAM processes (minutes)
```

## Compilation pipeline

### Lexer (`lib/vor/lexer.ex`)
NimbleParsec-based tokenizer. Handles keywords (`agent`, `state`, `protocol`, `on`, `emit`, `transition`, `safety`, `liveness`, `resilience`, `chaos`, `system`, `extern`, `invariant`, `where`, `sensitive`), operators, atoms, integers, strings, identifiers.

### Parser (`lib/vor/parser.ex`)
Recursive descent. Produces AST nodes for agents, state declarations, protocol blocks, handlers, invariants, system blocks, chaos blocks, and extern declarations.

Key recent additions:
- `where` clauses on `accepts` declarations (protocol constraints)
- `sensitive` keyword after state type annotations
- `chaos do ... end` blocks in system blocks

### AST (`lib/vor/ast.ex`)
Structs for every syntactic construct. Key types:
- `Agent` — top-level agent with params, states, protocol, handlers, invariants, externs
- `StateDecl` — name, type, enum values (if any), sensitive flag
- `Protocol` — accepts (with optional constraint), emits, sends
- `Handler` — message pattern, guard, body (transitions, emits, sends, if/else, extern calls)
- `Safety` / `Liveness` — invariant declarations with guarantee tier
- `System` — agent instances, connections, system-level invariants, chaos config
- `ChaosConfig` — duration, seed, kill/partition/delay/drop/workload/check settings

### IR (`lib/vor/ir.ex`)
Lowered representation consumed by both the verifier and codegen. Key difference from AST: handler bodies are action trees (transitions, conditionals, sends, emits) rather than raw syntax.

### Analysis
- **Safety verifier** — exhaustive state graph traversal for `proven` invariants
- **Handler completeness** — every `accepts` message has at least one handler
- **Protocol composition** — `sends` tags match `accepts` tags in connected agents
- **Internal type tracking** — type propagation through handler bodies
- **Extern proven boundary** — rejects proven invariants that depend on extern results

### Codegen (`lib/vor/codegen/erlang.ex`)
Produces Erlang abstract format, compiled via `:compile.forms/2`. Two agent types:
- gen_statem: agents with enum state fields
- gen_server: agents without enum state fields

Key codegen features:
- `__vor_transition__/4` wrapper function — handles state updates with telemetry and sensitive field redaction
- Telemetry calls generated at handler entry (received), state changes (transition), replies (emitted), and constraint violations
- Protocol constraint checks generated as early-return guards before handler body
- `__vor_agent_name__` stored in data map for telemetry metadata

## Module map

### Core pipeline
- `lib/vor/lexer.ex` — tokenizer
- `lib/vor/parser.ex` — recursive descent parser
- `lib/vor/ast.ex` — AST node structs
- `lib/vor/ir.ex` — IR node structs
- `lib/vor/lowering.ex` — AST → IR transformation
- `lib/vor/compiler.ex` — orchestrates the pipeline
- `lib/vor/codegen/erlang.ex` — IR → Erlang abstract format

### Verification
- `lib/vor/verifier.ex` — single-agent safety verification
- `lib/vor/graph.ex` — state graph extraction and Mermaid output
- `lib/vor/type_tracker.ex` — internal type propagation

### Multi-agent model checking
> ⚠️ **Correctness caveats (July 2026) — see `KNOWN_ISSUES.md`.** The successor
> relation does not fire timer/timeout/resilience transitions, so behavior gated
> behind those is never explored and invariants about it are vacuous. Symmetry
> canonicalization is not orbit-exact (unsound). The identifier-routing bug in
> directed sends is fixed. Treat multi-agent results accordingly.

- `lib/vor/explorer.ex` — product state BFS exploration
- `lib/vor/explorer/product_state.ex` — combined agent state representation
- `lib/vor/explorer/simulator.ex` — IR interpretation for handler simulation
- `lib/vor/explorer/successor.ex` — successor state generation
- `lib/vor/explorer/invariant.ex` — system-level invariant evaluation
- `lib/vor/explorer/relevance.ex` — cone-of-influence field analysis
- `lib/vor/explorer/symmetry.ex` — symmetry detection and canonicalization
- `lib/vor/explorer/vacuity.ex` — invariant **relevance** axis (subject reachability → substantive/vacuous/unexercised)
- `lib/vor/explorer/coverage.ex` — declared-vs-reached coverage (unreached enum values, unfired handlers/resilience/timers)

**Two-axis guarantees (Phase 1).** Every invariant reports strength (`proven` /
`checked` / `monitored`) *and* relevance (`substantive` / `vacuous` /
`unexercised`). Relevance comes from `Invariant.subject_active?/2`: extract the
invariant's subject (the atomic condition it constrains) and check whether it was
ever true in the explored space. A `proven`-tier invariant that is vacuous over
an exhaustive run is a hard error (`{:error, :vacuous_proven, …}`; `mix vor.check`
raises); `--allow-vacuous` downgrades it. Handler-firing coverage is instrumented
via the transient `ProductState.last_handler` tag and the `coverage: true` option
on `Successor.successors/4` (returns `{successors, fired_handler_ids}`).

### Chaos simulation
- `lib/vor/simulator.ex` — orchestrator: starts system, runs fault/invariant/workload loops
- `lib/vor/simulator/message_proxy.ex` — GenServer wrapping agents for message interception
- `lib/vor/simulator/supervisor_builder.ex` — builds proxy-aware supervisor tree
- `lib/vor/simulator/invariant_checker.ex` — queries live state, evaluates invariants
- `lib/vor/simulator/timeline.ex` — timestamped event log
- `lib/vor/simulator/workload.ex` — protocol-driven message generation
- `lib/mix/tasks/vor.simulate.ex` — mix task with CLI flags

### Mix tasks
- `lib/mix/tasks/vor.compile.ex` — compile .vor files
- `lib/mix/tasks/vor.check.ex` — multi-agent model checking
- `lib/mix/tasks/vor.simulate.ex` — chaos simulation
- `lib/mix/tasks/vor.graph.ex` — state graph extraction
- `lib/mix/tasks/vor.compat.ex` — protocol version compatibility checking
- `lib/mix/tasks/vor.surface.ex` — queryable spec inventory (JSON/text)
- `lib/mix/tasks/vor.coverage.ex` — verification posture report (JSON/text)

## State field types

| Type | Default value | gen_statem | gen_server |
|---|---|---|---|
| Enum (`:a \| :b \| :c`) | First declared value | State atom | Data map field |
| `integer` | 0 | Data map | Data map |
| `atom` | `:nil` | Data map | Data map |
| `map` | `%{}` | Data map | Data map |
| `list` | `[]` | Data map | Data map |
| `binary` | `""` | Data map | Data map |
| `term` | `nil` | Data map | Data map |

## Telemetry events

Generated automatically in codegen when `config :vor, telemetry: true` (default).

| Event | When | Metadata |
|---|---|---|
| `[:vor, :agent, :start]` | init callback | agent, type, initial_state |
| `[:vor, :message, :received]` | handler entry | agent, message_tag, state |
| `[:vor, :transition]` | state field change | agent, field, from, to |
| `[:vor, :message, :emitted]` | emit/reply | agent, message_tag |
| `[:vor, :constraint, :violated]` | protocol constraint failure | agent, message_tag, constraint |

Sensitive fields: transitions emit `from: :redacted, to: :redacted` for fields declared with `sensitive`.

Disable with `config :vor, telemetry: false` — codegen skips all telemetry calls.

## Protocol constraints

```vor
accepts {:transfer, amount: integer} where amount > 0 and amount < 100000
```

Codegen generates a constraint check as the first expression in the handler. If the constraint fails:
- Returns `{:error, {:constraint_violated, tag, description}}`
- Emits `[:vor, :constraint, :violated]` telemetry
- Handler body never executes

Constraint expressions use the same grammar as handler guards: comparisons (`>`, `<`, `>=`, `<=`, `==`, `!=`), boolean operators (`and`, `or`), field references, integer and atom literals, cross-field comparisons.

## Sensitive fields

```vor
state token: binary sensitive
```

The `sensitive` flag flows through AST → IR → codegen. The codegen builds a set of sensitive field names on each module. The `__vor_transition__/4` wrapper checks this set and redacts values in telemetry metadata.

## Chaos simulation

### Architecture

```
mix vor.simulate
  ├── SupervisorBuilder (proxy-aware supervisor tree)
  │     ├── Registry
  │     ├── MessageProxy :n1 → real Agent :n1
  │     ├── MessageProxy :n2 → real Agent :n2
  │     └── MessageProxy :n3 → real Agent :n3
  ├── Fault injector (parallel task)
  │     └── kill / partition / delay at random intervals
  ├── Workload generator (parallel task)
  │     └── sends accepts-matching messages at configured rate
  └── Invariant checker (parallel task)
        └── queries :sys.get_state via proxy, evaluates invariants
```

Proxy processes register under agent names in the Registry. Real agents start inside proxies without registration. Other agents send to proxies unknowingly. Fault policies (`:forward`, `:partition`, `:delay`, `:drop`) applied per-proxy.

### Chaos block syntax

System blocks accept an optional `chaos do ... end` block with declarative fault injection policies. When present, `mix vor.simulate` reads the config from the file. CLI flags override file values.

```vor
chaos do
  duration 60s
  seed 42

  kill every: 5..15s
  partition duration: 1..5s
  delay by: 50..200ms
  drop probability: 1
  workload rate: 10
  check every: 500ms
end
```

All fields are optional. Omitted fields use defaults:

| Field | Default | Description |
|---|---|---|
| `duration` | 30s | Simulation length. Accepts unit suffixes: `30s`, `5m`, `120000` (ms) |
| `seed` | random | Integer seed for reproducibility |
| `kill every: MIN..MAXs` | 3..10s | Interval range between agent kills |
| `partition duration: MIN..MAXs` | disabled | Partition duration range (presence enables partitions) |
| `delay by: MIN..MAXms` | disabled | Message delay range (presence enables delays) |
| `drop probability: N` | disabled | Random message drop, N as integer percentage (1 = 1%) |
| `workload rate: N` | 0 | Client messages per second |
| `check every: Nms` | 1s | Interval between invariant checks |

### Range and duration syntax

Ranges use `MIN..MAX` with an optional unit suffix:

```vor
kill every: 5..15s          %% 5000..15000 ms
partition duration: 1..5s   %% 1000..5000 ms
delay by: 50..200ms         %% 50..200 ms
delay by: 50..200           %% 50..200 ms (bare integers = ms)
```

Duration values accept `s` (seconds), `m` (minutes), or `ms` (milliseconds):

```vor
duration 60s    %% 60000 ms
duration 5m     %% 300000 ms
duration 30000  %% 30000 ms
```

### Config merging

CLI flags override chaos-block values. If no `chaos` block and no CLI flags, defaults are used.

```bash
# Uses file config
mix vor.simulate

# File config with duration overridden
mix vor.simulate --duration 120000

# Ignores file config for faults, uses CLI
mix vor.simulate --partition --delay --workload 20
```

### Modules

- `lib/vor/simulator.ex` — orchestrator, config merging
- `lib/vor/simulator/message_proxy.ex` — GenServer proxy with fault policies
- `lib/vor/simulator/supervisor_builder.ex` — proxy-aware supervisor tree
- `lib/vor/simulator/workload.ex` — protocol-driven message generation
- `lib/vor/simulator/invariant_checker.ex` — live state querying via `:sys.get_state`
- `lib/vor/simulator/timeline.ex` — Agent-backed event log
- `lib/mix/tasks/vor.simulate.ex` — mix task

## Model checker architecture

Product state = all agent states + pending messages. BFS exploration from initial state.

State space reduction:
- **Cone-of-influence** — only track fields transitively relevant to the invariant
- **Integer saturation** — bound tracked integers (default 3)
- **Queue bounding** — bound pending message queue (default 10)
- **Symmetry** — canonicalize agent ordering for homogeneous systems

Handler simulation interprets IR action trees directly (same IR as codegen). Extern results are `:unknown` — conditionals on `:unknown` fork both branches (conservative over-approximation).

## Liveness verification

### Single-agent (compile time)

`liveness "name" proven do always(P implies eventually(Q)) end` is verified during `mix compile`. The verifier checks: from every state where P holds but Q doesn't, is there a reachable path to a state where Q holds? If not (dead end or cycle back to non-Q states), the invariant is violated and compilation fails.

Uses the existing state graph built for safety verification. Implemented in `Vor.Explorer.LivenessChecker.check_single_agent/2`.

### Multi-agent (`mix vor.check`)

System blocks accept `liveness "name" proven do ... end` alongside `safety` declarations. After BFS exploration, the explorer:

1. Builds an adjacency map from the explored product state graph
2. Runs Tarjan's SCC algorithm (O(V+E)) to find non-trivial cycles
3. For each SCC, checks if any liveness obligation is active (P holds) but never fulfilled (Q never holds)
4. Terminal states (no outgoing transitions) with unfulfilled obligations are also flagged

Liveness field references are extracted from raw body tokens so the relevance analysis correctly tracks them.

Modules:
- `lib/vor/explorer/tarjan.ex` — Tarjan's SCC algorithm
- `lib/vor/explorer/liveness_checker.ex` — body parser + single/multi-agent checking

## Backpressure

```vor
agent Worker do
  max_queue 500                                    # agent-level limit

  protocol do
    accepts {:task} max_queue: 100                 # per-message override
    accepts {:health} priority: true               # bypasses backpressure
    emits {:ok}
  end
end
```

Codegen inserts a queue check before the handler body using `erlang:process_info(self(), message_queue_len)`. When the limit is exceeded:
- Calls return `{:error, {:backpressure, :queue_full}}`
- Casts are silently dropped
- Priority messages bypass the check entirely

Fires `[:vor, :backpressure, :rejected]` telemetry on rejection.

Per-message `max_queue:` overrides agent-level `max_queue`. Priority messages always have `backpressure_limit: nil`.

## `requires` declarations

```vor
system KvCluster do
  requires :vordb                    # OTP application
  requires VorDB.RingManager         # module with start_link

  agent :v1, KvStore(node_id: :node1)
  ...
end
```

`requires` declares infrastructure dependencies that `mix vor.simulate` starts before agents and stops (reverse order) after simulation. Handles `{:already_started, pid}` gracefully. The model checker (`mix vor.check`) ignores `requires` entirely.

## Protocol version compatibility

```bash
mix vor.compat new.vor --against old.vor
```

`Vor.Compat.check/2` compares two protocol versions and classifies each change:

| Change | Direction | Compatible? |
|---|---|---|
| Add accepts tag | — | ✓ (old agents won't send it) |
| Remove accepts tag | — | ✗ (old agents may still send) |
| Add field to accepts (with default) | — | ✓ |
| Add field to accepts (no default) | — | ✗ |
| Remove field from accepts | — | ✓ (receiver ignores extra) |
| Add emits tag | — | ✓ (old receivers ignore) |
| Remove emits tag | — | ✗ (old receivers may depend) |
| Remove field from emits | — | ✗ |
| Widen field type (integer → term) | — | ✓ |
| Narrow field type (term → integer) | — | ✗ |

The mix task reads defaults straight from the compiled IR (`Vor.Compat.check/2` keys on `field.default`), so adding a field with a `default:` is reported COMPATIBLE end to end from two real `.vor` files.

## Default values on accepts fields

```vor
protocol do
  accepts {:order, customer: atom, item: atom, quantity: integer default: 1}
end
```

`default:` follows the field's type and takes an integer, atom, boolean, or string literal. It is valid only on `accepts` — a default on `emits`/`sends` is a parse error (the sender always supplies every field). `default` is a *contextual* keyword: it is recognized only in this position, so it remains usable as an ordinary identifier (e.g. `default = ...` in a handler body).

The default is stored in a `defaults` map on `AST.MessageSpec` / `IR.MessageType` (keyed by field name); the `fields` list keeps its `{name, type}` shape, so existing consumers are untouched. At runtime the compiled handler merges defaults before binding:

```erlang
%% on {:order, ...} where quantity has default: 1
handle_event({call, From}, {order, VorFields0 = #{customer := C, item := I}}, State, Data) ->
    VorFields = maps:merge(#{quantity => 1}, VorFields0),  %% sender's value wins
    Quantity = maps:get(quantity, VorFields),
    ...
```

Only handlers whose tag actually declares a default are rewritten this way (the whole map is aliased in the head, non-defaulted fields stay exact-matched, defaulted fields are bound from the merged map). Agents with no defaults generate identical code to before. Applies to `gen_server` (`handle_call`/`handle_cast`) and `gen_statem` (`handle_event`) alike.

## Spec inventory (`mix vor.surface`)

```bash
mix vor.surface                          # all .vor in lib/ + examples/, JSON
mix vor.surface --file examples/lock.vor # single file
mix vor.surface --format text            # human-readable
```

`Vor.Surface.extract_source/2` (and `extract/2` on an already-parsed program) walks the AST and returns a JSON-serializable map per file: agents (with derived `gen_server`/`gen_statem` `type`, params, states), protocol (accepts with `where`/`max_queue`/`priority`/`defaults`, plus emits), safety/liveness invariants, backpressure, externs, and systems (instances, connections, `requires`, invariants, chaos). It is strictly read-only — it never runs verification or mutates the parser/AST.

Two reconstruction notes: invariant **bodies** are kept by the parser as raw token lists, so `Vor.Surface` re-renders them to source-like strings (e.g. `never(phase == :held and emitted({:grant, _}))`); `where` constraints are rebuilt from their structured AST. **System** safety bodies are stored structured (no verbatim tokens) and are rendered via `inspect/1`. The agent `type` is derived with the same rule as `Vor.Lowering`: an enum (atom-union) state field ⇒ `gen_statem`, otherwise `gen_server`.

## Verification posture (`mix vor.coverage`)

```bash
mix vor.coverage                 # all .vor in lib/ + examples/, text
mix vor.coverage --format json   # JSON with score percentages, for CI gates
mix vor.coverage --file examples # a path or directory
```

`Vor.Coverage.analyze/1` consumes a list of `Vor.Surface` file maps and returns a `%Vor.Coverage{}` struct: agent/system counts and how many carry each defense (safety, liveness, `where`, backpressure, sensitive fields, fully-native), invariant counts by tier, protocol coverage, and a `gaps` list. `format_text/2` and `format_json/1` render it. It reuses `Vor.Surface` rather than re-extracting, and runs no verification — gaps are informational, not build errors (CI enforces its own thresholds against the JSON `score`).

Gap rules: an agent is flagged for a missing safety invariant, missing liveness invariant, or no `where` constraint on any of its accepts; a system for missing safety, missing liveness, missing chaos block, or — only when its agent types declare externs — a missing `requires`. `bounded_verified` is always empty here because coverage never runs `mix vor.check`; populate it from a check run if you wire the two together. Metric helpers normalize atom-or-string `kind`/`tier` so the analyzer is robust to either shape.

## Test organization

- `test/features/` — feature-level tests (telemetry, simulation, constraints, model checking)
- `test/examples/` — example-specific tests (lock, circuit breaker, raft, gcounter, rate limiter)
- `test/unit/` — unit tests for individual modules (lexer, parser, codegen)
- `test/property/` — property-based tests (9 suites)

## Two-language stack

- **Vor** — coordination: state machines, protocols, invariants, verification, chaos, telemetry
- **Gleam** — data processing: type-safe functions called through `extern gleam do ... end`

Gleam extern type signatures are validated against `package-interface.json` at compile time. Extern results are opaque to the model checker (`:unknown`). Proven invariants cannot depend on extern results.

All five shipped examples are fully native Vor — zero externs.
