defmodule Vor.Simulator.Coverage do
  @moduledoc """
  Declared-vs-observed coverage for a simulation run (Phase 2b, task 2b.2).

  Vor's compiler already emits `:telemetry` events from generated agents —
  `[:vor, :transition]`, `[:vor, :message, :received]`, and
  `[:vor, :message, :emitted]`. This module attaches a lightweight collector to
  that existing stream for the lifetime of a run, then compares what the run
  *observed* against what the program *declared* (enum state values, accepted
  and emitted message tags, handlers).

  This is the simulation-tier analogue of the model checker's declared-but-
  unreached warning (`Vor.Explorer.Coverage`): the difference between "the
  program can do X" and "this run actually did X". It is only possible because
  Vor has a machine-readable declaration to compare the telemetry against.

  ## Lifecycle

      collector = Coverage.start()
      # ... run the simulation; agents emit telemetry ...
      report = Coverage.stop(collector, system_info)

  The collector holds observations in a public ETS table so telemetry handlers
  (which run inline in the emitting agent process) only do a cheap insert.
  """

  @events [
    [:vor, :transition],
    [:vor, :message, :received],
    [:vor, :message, :emitted]
  ]

  @doc """
  Start a coverage collector: create the observation table and attach telemetry
  handlers for the run. Returns an opaque handle to pass to `stop/2`.
  """
  def start do
    table = :ets.new(:vor_sim_coverage, [:set, :public])
    handler_id = {:vor_sim_coverage, make_ref()}

    :telemetry.attach_many(handler_id, @events, &__MODULE__.handle_event/4, table)

    %{table: table, handler_id: handler_id}
  end

  @doc """
  Detach the handlers, read the observations, and build the declared-vs-observed
  report against `system_info`. Safe to call once per collector.
  """
  def stop(%{table: table, handler_id: handler_id}, system_info) do
    :telemetry.detach(handler_id)
    observed = read_observed(table)
    :ets.delete(table)
    report(observed, system_info)
  end

  @doc false
  # Telemetry callback. Runs inline in the emitting agent process, so it must be
  # cheap and must never raise. Records only the observed *fact* (agent + value),
  # deduped by the ETS set.
  def handle_event([:vor, :transition], _measurements, meta, table) do
    agent = Map.get(meta, :agent, :undefined)
    field = Map.get(meta, :field)
    to = Map.get(meta, :to)
    from = Map.get(meta, :from)
    if valid_state?(to), do: :ets.insert(table, {{:state, agent, field, to}})
    if valid_state?(from), do: :ets.insert(table, {{:state, agent, field, from}})
    :ok
  rescue
    _ -> :ok
  end

  def handle_event([:vor, :message, :received], _measurements, meta, table) do
    agent = Map.get(meta, :agent, :undefined)
    tag = Map.get(meta, :message_tag)
    if tag, do: :ets.insert(table, {{:received, agent, tag}})
    :ok
  rescue
    _ -> :ok
  end

  def handle_event([:vor, :message, :emitted], _measurements, meta, table) do
    agent = Map.get(meta, :agent, :undefined)
    tag = Map.get(meta, :message_tag)
    if tag, do: :ets.insert(table, {{:emitted, agent, tag}})
    :ok
  rescue
    _ -> :ok
  end

  def handle_event(_event, _measurements, _meta, _table), do: :ok

  # The transition codegen emits `:redacted` placeholders under symmetry
  # fingerprinting, and `:unknown`/`:undefined` when a from-state can't be
  # determined statically. None of those are real reached values.
  defp valid_state?(v) when v in [nil, :redacted, :unknown, :undefined], do: false
  defp valid_state?(v) when is_atom(v), do: true
  defp valid_state?(_), do: false

  # ------------------------------------------------------------------
  # Observation reading
  # ------------------------------------------------------------------

  defp read_observed(table) do
    rows = :ets.tab2list(table)

    states =
      for {{:state, agent, field, value}} <- rows,
          reduce: %{} do
        acc -> put_nested(acc, [agent, field], value)
      end

    received =
      for {{:received, agent, tag}} <- rows, reduce: %{} do
        acc -> Map.update(acc, agent, MapSet.new([tag]), &MapSet.put(&1, tag))
      end

    emitted =
      for {{:emitted, agent, tag}} <- rows, reduce: %{} do
        acc -> Map.update(acc, agent, MapSet.new([tag]), &MapSet.put(&1, tag))
      end

    %{states: states, received: received, emitted: emitted}
  end

  defp put_nested(map, [k1, k2], value) do
    inner = Map.get(map, k1, %{})
    inner = Map.update(inner, k2, MapSet.new([value]), &MapSet.put(&1, value))
    Map.put(map, k1, inner)
  end

  # ------------------------------------------------------------------
  # Declared-vs-observed report
  # ------------------------------------------------------------------

  @doc """
  Build the declared-vs-observed report from an `observed` map (as produced
  internally) and `system_info`. Exposed for testing.
  """
  def report(observed, system_info) do
    declared = declared_surface(system_info)

    agents =
      Enum.into(declared, %{}, fn {name, decl} ->
        {name, agent_report(name, decl, observed)}
      end)

    %{agents: agents, totals: totals(agents)}
  end

  defp agent_report(name, decl, observed) do
    obs_states = get_in(observed, [:states, name]) || %{}
    obs_received = Map.get(observed.received, name, MapSet.new())
    obs_emitted = Map.get(observed.emitted, name, MapSet.new())

    states =
      Enum.into(decl.states, %{}, fn {field, values} ->
        reached = Map.get(obs_states, field, MapSet.new())
        {field, cmp(values, reached)}
      end)

    %{
      states: states,
      handlers: cmp(decl.handlers, obs_received),
      accepts: cmp(decl.accepts, obs_received),
      emits: cmp(decl.emits, obs_emitted)
    }
  end

  # Compare a declared set against an observed set. Both are normalized to sorted
  # lists; `missing` is declared-but-never-observed (the strong signal).
  defp cmp(declared, observed) do
    declared_set = MapSet.new(declared)
    observed_set = MapSet.new(observed)
    reached = MapSet.intersection(declared_set, observed_set)

    %{
      declared: Enum.sort(declared_set),
      reached: Enum.sort(reached),
      missing: Enum.sort(MapSet.difference(declared_set, observed_set))
    }
  end

  defp totals(agents) do
    Enum.reduce(agents, blank_totals(), fn {_name, rep}, acc ->
      acc
      |> add(:states, count_states(rep.states))
      |> add(:handlers, {length(rep.handlers.reached), length(rep.handlers.declared)})
      |> add(:accepts, {length(rep.accepts.reached), length(rep.accepts.declared)})
      |> add(:emits, {length(rep.emits.reached), length(rep.emits.declared)})
    end)
  end

  defp count_states(states) do
    Enum.reduce(states, {0, 0}, fn {_field, c}, {r, d} ->
      {r + length(c.reached), d + length(c.declared)}
    end)
  end

  defp add(totals, key, {reached, declared}) do
    {r0, d0} = Map.get(totals, key)
    Map.put(totals, key, {r0 + reached, d0 + declared})
  end

  defp blank_totals do
    %{states: {0, 0}, handlers: {0, 0}, accepts: {0, 0}, emits: {0, 0}}
  end

  # ------------------------------------------------------------------
  # Declared surface (from the compiled IR carried in system_info)
  # ------------------------------------------------------------------

  @doc """
  Extract the declared surface per agent *instance* from `system_info`:
  enum state values, handler tags, accepted and emitted message tags. Keyed by
  instance name to match the `agent` metadata telemetry carries
  (`__vor_agent_name__`).
  """
  def declared_surface(system_info) do
    surface = system_info[:declared_surface]
    if is_map(surface), do: surface, else: %{}
  end
end
