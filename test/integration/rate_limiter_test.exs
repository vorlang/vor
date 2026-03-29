defmodule Vor.Integration.RateLimiterTest do
  use ExUnit.Case

  test "rate limiter compiles successfully" do
    source = File.read!("test/fixtures/rate_limiter.vor")
    {:ok, result} = Vor.Compiler.compile_and_load(source)

    assert result.module == Vor.Agent.RateLimiter
    assert result.ir.behaviour == :gen_statem
    assert [%{name: :phase}] = result.ir.state_fields
  end

  test "rate limiter has relation and invariant" do
    source = File.read!("test/fixtures/rate_limiter.vor")
    {:ok, result} = Vor.Compiler.compile_string(source)

    assert [relation] = result.ir.relations
    assert relation.name == :rate_limit
    assert length(relation.facts) == 1

    assert [{:safety, "rate limit respected", :proven}] = result.ir.invariants
  end

  test "rate limiter accepts requests in accepting state" do
    source = File.read!("test/fixtures/rate_limiter.vor")
    {:ok, result} = Vor.Compiler.compile_and_load(source)

    {:ok, pid} = :gen_statem.start_link(result.module, [], [])

    # Initial state is :accepting (first in union)
    assert {:accepting, _} = :sys.get_state(pid)

    :gen_statem.stop(pid)
  end

  test "rate limiter protocol declares accepts and emits" do
    source = File.read!("test/fixtures/rate_limiter.vor")
    {:ok, result} = Vor.Compiler.compile_string(source)

    accept_tags = Enum.map(result.ir.protocol.accepts, & &1.tag)
    emit_tags = Enum.map(result.ir.protocol.emits, & &1.tag)

    assert :request in accept_tags
    assert :ok in emit_tags
    assert :rejected in emit_tags
  end
end
