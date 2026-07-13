defmodule Vor.Features.TimerFiringTest do
  @moduledoc """
  Phase 3a — the explorer fires timer/timeout/resilience transitions as
  nondeterministic successors. These are the behaviors that were dead code
  during verification (making results vacuous); firing them makes the model
  honest.
  """
  use ExUnit.Case, async: true

  alias Vor.Explorer

  defp reachable_roles(source, opts) do
    res = Explorer.check_file(source, opts)
    stats = res |> Tuple.to_list() |> List.last()

    stats.state_map
    |> Map.values()
    |> Enum.flat_map(fn ps -> Enum.map(ps.agents, fn {_n, s} -> Map.get(s, :role) end) end)
    |> MapSet.new()
  end

  test "firing the election timeout makes :candidate and :leader reachable in Raft" do
    source = File.read!("examples/raft_cluster.vor")
    opts = [max_depth: 12, max_states: 500_000, integer_bound: 2, max_queue: 2, symmetry: false, allow_vacuous: true]

    # Timers ON (default): election fires, leadership is reached.
    on = reachable_roles(source, opts)
    assert MapSet.member?(on, :candidate)
    assert MapSet.member?(on, :leader)

    # Timers OFF: the old blind mode — every node stays a follower.
    off = reachable_roles(source, Keyword.put(opts, :fire_timers, false))
    assert MapSet.equal?(off, MapSet.new([:follower]))
  end

  test "firing the recovery timer makes circuit-breaker :half_open reachable" do
    source =
      File.read!("examples/circuit_breaker.vor") <>
        """

        system P do
          agent :cb, CircuitBreaker()
          safety "probe" checked do
            never(count(agents where phase == :half_open) > 9)
          end
        end
        """

    opts = [max_depth: 15, max_states: 100_000, symmetry: false]

    phases = fn o ->
      stats = Explorer.check_file(source, o) |> Tuple.to_list() |> List.last()

      stats.state_map
      |> Map.values()
      |> Enum.flat_map(fn ps -> Enum.map(ps.agents, fn {_n, s} -> Map.get(s, :phase) end) end)
      |> MapSet.new()
    end

    assert MapSet.member?(phases.(opts), :half_open)
    refute MapSet.member?(phases.(Keyword.put(opts, :fire_timers, false)), :half_open)
  end

  test "a periodic `every` timer fires (G-Counter gossip)" do
    source =
      File.read!("examples/gcounter_cluster.vor")
      |> String.replace(~r/\nend\s*\z/, """

        safety "probe" checked do
          never(count(agents where counts == :__x__) > 9)
        end
      end
      """)

    {:ok, _status, stats} =
      Explorer.check_file(source, max_depth: 15, max_states: 500_000, max_queue: 4, symmetry: false)

    # The gossip `every` timer fired at least once (recorded with an {:every, tag} id).
    assert Enum.any?(stats.fired_handlers, &match?({_type, {:every, _tag}}, &1)),
           "the periodic gossip timer never fired"

    # And the coverage report no longer lists it as an unfired timer.
    assert stats.coverage.unfired_timers == []
  end
end
