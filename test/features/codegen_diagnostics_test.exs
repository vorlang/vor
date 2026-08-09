defmodule Vor.CodegenDiagnosticsTest do
  @moduledoc """
  F9 / F12 regression: two plausible source constructs used to crash codegen
  with raw Erlang `erl_lint` `unbound_var` errors instead of compiling or giving
  a Vor diagnostic.

  - F9: a single-value enum state (`state phase: :running`) — now a valid
    one-state machine.
  - F12: a parameterised send target (`send peer {...}`) — now resolves the
    param from the agent's data map and routes correctly.

  Both are verified by observable effect (real `:sys.get_state`), not telemetry.
  """
  use ExUnit.Case

  @moduletag :simulation

  alias Vor.Simulator.{SupervisorBuilder, MessageProxy}

  defp start(src) do
    {:ok, si} = Vor.Simulator.compile_for_simulation(src)
    {:ok, sup} = SupervisorBuilder.start_link(si)
    Process.sleep(300)
    {si, sup}
  end

  defp real(si, name) do
    [{p, _}] = Registry.lookup(si.registry, name)
    MessageProxy.get_real_pid(p)
  end

  test "F9: a single-value enum state compiles and its guarded handler runs" do
    src = """
    agent Counter() do
      state phase: :running
      state n: integer
      protocol do
        accepts {:tick}
      end
      on {:tick} when phase == :running do
        transition n: n + 1
      end
    end
    system S do
      agent :c, Counter()
    end
    """

    assert {:ok, _} = Vor.Compiler.compile_system(src)

    {si, sup} = start(src)
    c = real(si, :c)
    :gen_statem.cast(c, {:tick, %{}})
    :gen_statem.cast(c, {:tick, %{}})
    Process.sleep(120)
    {state, data} = :sys.get_state(c)
    assert state == :running
    assert Map.get(data, :n) == 2
    Supervisor.stop(sup)
  end

  test "F12: a parameterised send target compiles and routes to the named agent" do
    src = """
    agent Relay(peer: atom) do
      state s: :on | :off
      protocol do
        accepts {:go}
        sends {:ping}
      end
      on {:go} when s == :on do
        send peer {:ping}
      end
    end
    agent Sink() do
      state got: :no | :yes
      protocol do
        accepts {:ping}
      end
      on {:ping} when got == :no do
        transition got: :yes
      end
    end
    system S do
      agent :relay, Relay(peer: :sink)
      agent :sink, Sink()
      connect :relay -> :sink
    end
    """

    assert {:ok, _} = Vor.Compiler.compile_system(src)

    {si, sup} = start(src)
    relay = real(si, :relay)
    sink = real(si, :sink)
    :gen_statem.cast(relay, {:go, %{}})
    Process.sleep(150)
    {state, _} = :sys.get_state(sink)
    assert state == :yes, "the param-targeted send should have reached :sink"
    Supervisor.stop(sup)
  end
end
