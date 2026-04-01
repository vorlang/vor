defmodule Vor.Examples.RateLimiterTest do
  use ExUnit.Case

  alias Vor.Examples.RateStore

  setup do
    RateStore.reset()
    source = File.read!("examples/rate_limiter.vor")
    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [max_requests: 3, window_ms: 60_000])
    %{pid: pid, module: result.module}
  end

  test "accepts requests within limit", %{pid: pid} do
    result = GenServer.call(pid, {:request, %{client: "alice", payload: "hello"}})
    assert {:ok, %{payload: "hello", remaining: 2}} = result
  end

  test "decrements remaining count", %{pid: pid} do
    GenServer.call(pid, {:request, %{client: "alice", payload: "req1"}})
    result = GenServer.call(pid, {:request, %{client: "alice", payload: "req2"}})
    assert {:ok, %{payload: "req2", remaining: 1}} = result
  end

  test "rejects requests over limit", %{pid: pid} do
    GenServer.call(pid, {:request, %{client: "alice", payload: "req1"}})
    GenServer.call(pid, {:request, %{client: "alice", payload: "req2"}})
    GenServer.call(pid, {:request, %{client: "alice", payload: "req3"}})
    result = GenServer.call(pid, {:request, %{client: "alice", payload: "req4"}})
    assert {:rejected, %{client: "alice", retry_after: 60_000}} = result
  end

  test "different clients have independent limits", %{pid: pid} do
    GenServer.call(pid, {:request, %{client: "alice", payload: "req1"}})
    GenServer.call(pid, {:request, %{client: "alice", payload: "req2"}})
    GenServer.call(pid, {:request, %{client: "alice", payload: "req3"}})

    result = GenServer.call(pid, {:request, %{client: "bob", payload: "req1"}})
    assert {:ok, %{payload: "req1", remaining: 2}} = result
  end

  test "parameterized with different limits" do
    RateStore.reset()
    source = File.read!("examples/rate_limiter.vor")
    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [max_requests: 1, window_ms: 60_000])

    result1 = GenServer.call(pid, {:request, %{client: "alice", payload: "req1"}})
    assert {:ok, %{payload: "req1", remaining: 0}} = result1

    result2 = GenServer.call(pid, {:request, %{client: "alice", payload: "req2"}})
    assert {:rejected, %{client: "alice", retry_after: 60_000}} = result2

    GenServer.stop(pid)
  end
end
