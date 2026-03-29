# Vor

A programming language for the BEAM with relations, constraints, and verifiable invariants.

[vorlang.org](https://vorlang.org)

## Why

Programs should carry their own verification criteria. Vor is a declarative language where you write what must be true about your system — relations, protocols, invariants — and the compiler produces BEAM bytecode that satisfies those declarations. The spec is the program. There is no separate implementation to drift, review, or debug.

Vor compiles to Erlang/OTP, inheriting battle-tested concurrency, fault tolerance, and hot code reloading. At runtime, a Vor agent is indistinguishable from a hand-written gen_server or gen_statem.

## Example

A rate limiter in Vor:

```vor
agent RateLimiter do

  relation rate_limit(client: client_id, max_requests: integer) do
    fact(client: :default, max_requests: 10)
  end

  state phase: :accepting | :rejecting

  protocol do
    accepts {:request, client: client_id, payload: term}
    emits {:ok, payload: term}
    emits {:rejected, client: client_id}
  end

  on {:request, client: C, payload: P} when phase == :accepting do
    emit {:ok, payload: P}
  end

  on {:request, client: C, payload: P} when phase == :rejecting do
    emit {:rejected, client: C}
  end

  invariant "rate limit respected" proven do
    forall C, Max
      where rate_limit(client: C, max_requests: Max)
      -> count(requests(client: C)) <= Max
  end

end
```

The equivalent in Elixir would be a gen_statem with hand-written state machine clauses, manual rate tracking, and no way to express the invariant at all. The rate limit correctness property lives in your head or in a comment. In Vor, it's part of the program — tagged with its guarantee tier, checked by the compiler.

## What's working

- Full compiler pipeline: `.vor` source -> Lexer -> Parser -> AST -> IR -> Erlang codegen -> BEAM binary
- Agents compile to OTP `gen_server` and `gen_statem`
- Relations with facts, state declarations, protocols, handlers with guards
- Safety and liveness invariant declarations with guarantee tiers (proven, checked, monitored)
- Protocol conformance checking
- 26 tests passing

## What's coming

- Invariant verification (compile-time proof for safety properties)
- Runtime invariant monitoring (liveness watchdogs)
- Bidirectional relation solver
- Protocol composition checking between agents
- Synthesis obligations (AI-assisted implementation)

## Try it

```
git clone git@github.com:vorlang/vor.git
cd vor
mix deps.get
mix test
```

Then in the interactive shell:

```
iex -S mix

{:ok, result} = Vor.compile_and_load(File.read!("test/fixtures/rate_limiter.vor"))
{:ok, pid} = :gen_statem.start_link(result.module, [], [])
:sys.get_state(pid)
# => {:accepting, %{}}
```

## Background

- [The Vor Manifesto](https://vorlang.org) -- why this language needs to exist
- [One-pager](docs/onepager.md) -- technical overview
- [Paradigm comparison](docs/comparison.md) -- Mainstream vs Vor

## License

MIT
