# Vor

A programming language for the BEAM with relations, constraints, and verifiable invariants.

[vorlang.org](https://vorlang.org)

## Why

The hardest bugs in distributed systems aren't logic errors — they're the ones where the code does something nobody intended because nobody wrote down what it should do. Design docs drift from code on day one. Formal specs sit in a separate repo that nobody updates after launch. The implementation becomes the only source of truth, and it's a source that can't answer "is this correct?"

Vor is a language where you declare what must be true — state machines, message protocols, safety invariants — and the compiler produces BEAM bytecode that satisfies those declarations. One artifact. No drift. The spec is the program.

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

The equivalent in Elixir would be a gen_statem with hand-written state machine clauses, manual rate tracking, and invariants that exist only as tests or comments — not as compiler-verified properties of the code. The rate limit correctness property lives in your head or in a comment. In Vor, it's part of the program — tagged with its guarantee tier, checked by the compiler.

## What's working

- Full compiler pipeline: `.vor` source -> Lexer -> Parser -> AST -> IR -> Erlang codegen -> BEAM binary
- Agents compile to OTP `gen_server` and `gen_statem`
- Relations with facts, state declarations, protocols, handlers with guards
- Safety and liveness invariant declarations with guarantee tiers (proven, checked, monitored)
- Protocol conformance checking
- Extern declarations for calling Erlang/Elixir from Vor agents
- 25 tests passing

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
