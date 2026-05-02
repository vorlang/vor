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
- `lib/vor/explorer.ex` — product state BFS exploration
- `lib/vor/explorer/product_state.ex` — combined agent state representation
- `lib/vor/explorer/simulator.ex` — IR interpretation for handler simulation
- `lib/vor/explorer/successor.ex` — successor state generation
- `lib/vor/explorer/invariant.ex` — system-level invariant evaluation
- `lib/vor/explorer/relevance.ex` — cone-of-influence field analysis
- `lib/vor/explorer/symmetry.ex` — symmetry detection and canonicalization

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
