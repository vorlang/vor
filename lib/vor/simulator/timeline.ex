defmodule Vor.Simulator.Timeline do
  @moduledoc """
  Records timestamped events during chaos simulation. Backed by an Agent
  so all simulation tasks (fault injector, invariant checker, workload)
  can append concurrently.
  """

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> [] end)
  end

  def record(timeline, event_type, data \\ %{}) do
    ts = System.monotonic_time(:millisecond)
    Agent.update(timeline, fn events -> events ++ [{ts, event_type, data}] end)
  end

  def get(timeline) do
    Agent.get(timeline, & &1)
  end

  def recent(timeline, n) do
    Agent.get(timeline, fn events -> Enum.take(events, -n) end)
  end
end
