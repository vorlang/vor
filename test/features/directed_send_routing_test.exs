defmodule Vor.DirectedSendRoutingTest do
  @moduledoc """
  Regression tests for the identifier-routing bug (Phase 0, Task 0.1).

  A system-block param `node_id: :a` was stored as the unlowered AST literal
  `{:atom, "a"}` instead of the bare atom `:a`. A directed reply `send C {...}`
  whose target `C` comes from a message payload carrying a `node_id` was then
  addressed to `{:atom, "a"}`, which `Successor.dispatch` could not match against
  the agent keys (`:a`), so the reply was silently dropped.
  """
  use ExUnit.Case, async: true

  alias Vor.Explorer

  # Two agents. `:a` is kicked with {:start}, broadcasts {:ping, from: node_id}.
  # `:b` receives the ping and replies with `send F {:pong}` where F is the
  # node_id carried in the payload. `:a` reaches :ponged ONLY if that directed,
  # payload-addressed reply is actually delivered.
  @source """
  agent PingNode(node_id: atom) do
    state phase: :idle | :pinged | :ponged

    protocol do
      accepts {:start}
      accepts {:ping, from: atom}
      accepts {:pong}
      sends {:ping, from: atom}
      sends {:pong}
    end

    on {:start} when phase == :idle do
      transition phase: :pinged
      broadcast {:ping, from: node_id}
    end

    on {:ping, from: F} when phase == :idle do
      send F {:pong}
    end

    on {:pong} do
      transition phase: :ponged
    end
  end

  system PingPong do
    agent :a, PingNode(node_id: :a)
    agent :b, PingNode(node_id: :b)
    connect :a -> :b
    connect :b -> :a

    safety "probe" proven do
      never(count(agents where phase == :ponged) > 9)
    end
  end
  """

  test "system-block atom param is lowered to a bare atom, not {:atom, str}" do
    {:ok, comp} = Vor.Compiler.compile_system(@source)
    a = Enum.find(comp.system_ir.agents, &(&1.name == :a))
    assert Keyword.get(a.params, :node_id) == :a
    refute match?({:atom, _}, Keyword.get(a.params, :node_id))
  end

  test "a directed send whose target comes from a message payload is delivered" do
    {:ok, :proven, stats} =
      Explorer.check_file(@source, max_depth: 12, max_states: 50_000, symmetry: false)

    reached_ponged? =
      stats.state_map
      |> Map.values()
      |> Enum.any?(fn ps ->
        Enum.any?(ps.agents, fn {_name, st} -> Map.get(st, :phase) == :ponged end)
      end)

    assert reached_ponged?,
           "the :pong reply addressed to a payload-carried node_id was never delivered — routing regressed"
  end
end
