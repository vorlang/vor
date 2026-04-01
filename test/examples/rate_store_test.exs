defmodule Vor.Examples.RateStoreTest do
  use ExUnit.Case

  alias Vor.Examples.RateStore

  setup do
    RateStore.reset()
    :ok
  end

  test "increment returns increasing count" do
    assert RateStore.increment("client_a", 60_000) == 1
    assert RateStore.increment("client_a", 60_000) == 2
    assert RateStore.increment("client_a", 60_000) == 3
  end

  test "different clients have separate counts" do
    assert RateStore.increment("client_a", 60_000) == 1
    assert RateStore.increment("client_b", 60_000) == 1
    assert RateStore.increment("client_a", 60_000) == 2
    assert RateStore.increment("client_b", 60_000) == 2
  end

  test "count returns current count without incrementing" do
    RateStore.increment("client_a", 60_000)
    RateStore.increment("client_a", 60_000)
    assert RateStore.count("client_a", 60_000) == 2
  end

  test "count returns 0 for unknown client" do
    assert RateStore.count("unknown", 60_000) == 0
  end
end
