defmodule Vor.Simulator.Sweep do
  @moduledoc """
  Sweep-level aggregation across many seeds (Phase 2b, task 2b.4).

  A single seed exercises one path; the honest picture is the *union* across the
  sweep. This module runs the same system under N seeds and aggregates:

    * per-seed outcome counts — pass / under-tested / fail / error;
    * union coverage — which declared states / handlers / messages were reached
      by **at least one** seed, and (the strongest signal) which were reached by
      **none**;
    * per-invariant relevance — how many seeds found each invariant's subject
      live, and whether *any* did.

  "Reached by no seed" means the current fault/workload configuration cannot
  exercise that behaviour at all — a coverage hole, not noise.
  """

  alias Vor.Simulator

  @doc """
  Run `system_info` under each of `seeds`, returning the individual results
  alongside the aggregate. `base_config` is applied to every run with `:seed`
  overridden per seed.

  Returns `%{seeds: [...], runs: [%{seed, outcome, stats}], aggregate: %{...}}`.
  """
  def run(system_info, seeds, base_config) do
    runs =
      Enum.map(seeds, fn seed ->
        config = Map.put(base_config, :seed, seed)
        result = Simulator.run_system(system_info, config)
        summarize_run(seed, result)
      end)

    %{seeds: seeds, runs: runs, aggregate: aggregate(runs, system_info)}
  end

  defp summarize_run(seed, {:ok, outcome, stats}), do: %{seed: seed, outcome: outcome, stats: stats}

  defp summarize_run(seed, {:error, :violation, name, _details, stats}),
    do: %{seed: seed, outcome: :fail, violation: name, stats: stats}

  defp summarize_run(seed, {:error, kind, reason}),
    do: %{seed: seed, outcome: :error, error: {kind, reason}, stats: %{}}

  defp summarize_run(seed, {:error, kind, a, b}),
    do: %{seed: seed, outcome: :error, error: {kind, a, b}, stats: %{}}

  @doc """
  Aggregate a list of per-run summaries (as produced by `run/3`) into the
  sweep-level picture. Exposed for testing / offline aggregation.
  """
  def aggregate(runs, system_info) do
    %{
      run_count: length(runs),
      outcomes: outcome_counts(runs),
      coverage: union_coverage(runs, system_info),
      relevance: union_relevance(runs)
    }
  end

  defp outcome_counts(runs) do
    Enum.reduce(runs, %{pass: 0, under_tested: 0, fail: 0, error: 0}, fn run, acc ->
      Map.update(acc, run.outcome, 1, &(&1 + 1))
    end)
  end

  # ------------------------------------------------------------------
  # Union coverage across seeds
  # ------------------------------------------------------------------

  defp union_coverage(runs, system_info) do
    declared = Simulator.declared_surface_for(system_info)

    reports = for %{stats: %{coverage: cov}} <- runs, is_map(cov), do: cov

    agents =
      Enum.into(declared, %{}, fn {name, decl} ->
        {name, union_agent(name, decl, reports)}
      end)

    %{agents: agents, totals: sum_totals(agents)}
  end

  defp union_agent(name, decl, reports) do
    reached_states =
      Enum.into(decl.states, %{}, fn {field, values} ->
        reached =
          reports
          |> Enum.flat_map(fn cov ->
            get_in(cov, [:agents, name, :states, field, :reached]) || []
          end)
          |> MapSet.new()

        {field, cmp(values, reached)}
      end)

    reached_handlers = union_axis(reports, name, [:handlers, :reached])
    reached_accepts = union_axis(reports, name, [:accepts, :reached])
    reached_emits = union_axis(reports, name, [:emits, :reached])

    %{
      states: reached_states,
      handlers: cmp(decl.handlers, reached_handlers),
      accepts: cmp(decl.accepts, reached_accepts),
      emits: cmp(decl.emits, reached_emits)
    }
  end

  defp union_axis(reports, name, path) do
    reports
    |> Enum.flat_map(fn cov -> get_in(cov, [:agents, name] ++ path) || [] end)
    |> MapSet.new()
  end

  defp cmp(declared, reached_set) do
    declared_set = MapSet.new(declared)

    %{
      declared: Enum.sort(declared_set),
      reached: Enum.sort(MapSet.intersection(declared_set, reached_set)),
      missing: Enum.sort(MapSet.difference(declared_set, reached_set))
    }
  end

  defp sum_totals(agents) do
    Enum.reduce(agents, %{states: {0, 0}, handlers: {0, 0}, accepts: {0, 0}, emits: {0, 0}}, fn
      {_name, rep}, acc ->
        acc
        |> add(:states, count_states(rep.states))
        |> add(:handlers, {length(rep.handlers.reached), length(rep.handlers.declared)})
        |> add(:accepts, {length(rep.accepts.reached), length(rep.accepts.declared)})
        |> add(:emits, {length(rep.emits.reached), length(rep.emits.declared)})
    end)
  end

  defp count_states(states) do
    Enum.reduce(states, {0, 0}, fn {_f, c}, {r, d} ->
      {r + length(c.reached), d + length(c.declared)}
    end)
  end

  defp add(totals, key, {reached, declared}) do
    {r0, d0} = Map.get(totals, key)
    Map.put(totals, key, {r0 + reached, d0 + declared})
  end

  # ------------------------------------------------------------------
  # Union relevance across seeds
  # ------------------------------------------------------------------

  # For each invariant: how many seeds found its subject live, and was it live in
  # any seed at all? An invariant vacuous across the *entire* sweep is the strong
  # signal — the configuration can't exercise its subject.
  defp union_relevance(runs) do
    entries =
      for %{stats: %{relevance: rel}} <- runs, is_list(rel), inv <- rel, do: inv

    entries
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn {name, invs} ->
      substantive_seeds = Enum.count(invs, &(&1.relevance == :substantive))

      relevance =
        cond do
          substantive_seeds > 0 -> :substantive
          Enum.any?(invs, &(&1.relevance == :vacuous)) -> :vacuous
          true -> :unexercised
        end

      %{
        name: name,
        relevance: relevance,
        substantive_seeds: substantive_seeds,
        total_seeds: length(invs),
        subject: List.first(invs).subject
      }
    end)
  end
end
