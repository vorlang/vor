defmodule Vor.Explorer do
  @moduledoc """
  Multi-agent product-state exploration entry point.

  The explorer takes a compiled system (agents + system block + system-level
  safety invariants) and runs a BFS over the reachable product state space,
  checking each state against the declared invariants. On the first
  violation it returns a counterexample trace; if the BFS completes without
  finding one it returns `:proven`. If the depth or state-count bounds are
  hit first it returns `:bounded` so the user knows the verification is not
  exhaustive.

  Exploration runs only via `mix vor.check`. Standard `mix compile` parses
  the invariants and stores them on the system IR but does not run the BFS.
  """

  alias Vor.Explorer.{Invariant, ProductState, Relevance, Successor, Symmetry}
  alias Vor.IR

  @default_max_depth 50
  @default_max_states 100_000
  @default_integer_bound 3
  @default_max_queue 10

  @type stats :: %{
          states_explored: non_neg_integer(),
          max_depth_reached: non_neg_integer(),
          relevance: Relevance.t() | nil,
          integer_bound: non_neg_integer(),
          max_queue: non_neg_integer(),
          symmetry: boolean()
        }

  @doc """
  Compile the source and explore each system block. Convenience entry point
  used by `mix vor.check` and the test suite.
  """
  def check_file(source, opts \\ []) do
    case Vor.Compiler.compile_system(source, opts) do
      {:ok, %{system_ir: nil}} ->
        {:ok, :no_invariants, empty_stats()}

      {:ok, result} ->
        case result.system_ir.invariants do
          [] ->
            {:ok, :no_invariants, empty_stats()}

          invariants ->
            instance_irs = build_instance_irs(result)
            verify_system(result.system_ir, instance_irs, invariants, opts)
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Run BFS exploration and invariant checking against an already-built system.

  Phase 2 options:

    * `:integer_bound` — saturation cap for tracked integer fields (default 3)

  Relevance is computed automatically from the supplied invariants. The
  resulting per-instance map is included in the returned stats so callers
  (e.g. `mix vor.check`) can report what was tracked vs abstracted.
  """
  def verify_system(%IR.SystemIR{} = system_ir, instance_irs, invariants, opts \\ []) do
    max_depth = Keyword.get(opts, :max_depth, @default_max_depth)
    max_states = Keyword.get(opts, :max_states, @default_max_states)
    integer_bound = Keyword.get(opts, :integer_bound, @default_integer_bound)
    max_queue = Keyword.get(opts, :max_queue, @default_max_queue)
    symmetry_opt = Keyword.get(opts, :symmetry, :auto)
    symmetry = Symmetry.enabled?(system_ir, invariants, symmetry_opt)

    relevance = Relevance.compute(system_ir, instance_irs, invariants)

    initial =
      system_ir
      |> ProductState.initial(instance_irs)
      |> ProductState.abstract(relevance)
      |> saturate_initial(relevance, integer_bound)

    base_stats = %{
      states_explored: 1,
      max_depth_reached: 0,
      relevance: relevance,
      integer_bound: integer_bound,
      max_queue: max_queue,
      symmetry: symmetry
    }

    case check_all_invariants(initial, invariants) do
      {:violation, name} ->
        {:error, :violation, name, [initial], base_stats}

      :ok ->
        bfs(initial, instance_irs, system_ir, invariants, max_depth, max_states,
          relevance, integer_bound, max_queue, symmetry)
    end
  end

  defp saturate_initial(%ProductState{agents: agents} = ps, relevance, bound) do
    new_agents =
      Enum.into(agents, %{}, fn {name, state} ->
        case Map.get(relevance, name) do
          %{tracked_int: tracked_int} ->
            {name, ProductState.saturate_integers(state, tracked_int, bound)}

          _ ->
            {name, state}
        end
      end)

    %ProductState{ps | agents: new_agents}
  end

  # ----------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------

  defp build_instance_irs(%{system_ir: %IR.SystemIR{agents: instances}, agents: agent_results}) do
    Enum.into(instances, %{}, fn instance ->
      ir =
        case Map.get(agent_results, instance.type_name) do
          %{ir: ir} -> ir
          _ -> nil
        end

      {instance.name, ir}
    end)
  end

  defp empty_stats,
    do: %{
      states_explored: 0,
      max_depth_reached: 0,
      relevance: nil,
      integer_bound: @default_integer_bound,
      max_queue: @default_max_queue,
      symmetry: false
    }

  defp check_all_invariants(state, invariants) do
    Enum.find_value(invariants, :ok, fn inv ->
      case Invariant.check(state, inv) do
        :ok -> nil
        {:violation, name} -> {:violation, name}
      end
    end)
  end

  # ----------------------------------------------------------------------
  # BFS — uses an Erlang queue. Each queue entry carries the trace prefix
  # used to reconstruct the counterexample if a violation is found.
  # ----------------------------------------------------------------------

  defp bfs(initial, instance_irs, system_ir, invariants, max_depth, max_states, relevance, integer_bound, max_queue, symmetry) do
    queue = :queue.in({initial, [initial]}, :queue.new())
    visited = MapSet.new([fingerprint(initial, symmetry)])
    stats = %{
      states_explored: 1,
      max_depth_reached: 0,
      relevance: relevance,
      integer_bound: integer_bound,
      max_queue: max_queue,
      symmetry: symmetry
    }

    do_bfs(queue, visited, instance_irs, system_ir, invariants, max_depth, max_states, stats, relevance, integer_bound, max_queue, symmetry)
  end

  defp do_bfs(queue, visited, instance_irs, system_ir, invariants, max_depth, max_states, stats, relevance, integer_bound, max_queue, symmetry) do
    case :queue.out(queue) do
      {:empty, _} ->
        {:ok, :proven, stats}

      {{:value, {state, trace}}, rest} ->
        cond do
          stats.states_explored >= max_states ->
            {:ok, :bounded, stats}

          state.depth >= max_depth ->
            do_bfs(rest, visited, instance_irs, system_ir, invariants, max_depth, max_states, stats, relevance, integer_bound, max_queue, symmetry)

          true ->
            successors =
              Successor.successors(state, instance_irs, system_ir,
                relevance: relevance, integer_bound: integer_bound, max_queue: max_queue)

            step =
              Enum.reduce_while(successors, {rest, visited, stats, nil}, fn succ, {q, v, s, _} ->
                fp = fingerprint(succ, symmetry)

                if MapSet.member?(v, fp) do
                  {:cont, {q, v, s, nil}}
                else
                  new_visited = MapSet.put(v, fp)
                  new_stats = %{
                    s
                    | states_explored: s.states_explored + 1,
                      max_depth_reached: max(s.max_depth_reached, succ.depth)
                  }

                  case check_all_invariants(succ, invariants) do
                    {:violation, name} ->
                      {:halt, {q, new_visited, new_stats, {:violation, name, trace ++ [succ]}}}

                    :ok ->
                      new_q = :queue.in({succ, trace ++ [succ]}, q)
                      {:cont, {new_q, new_visited, new_stats, nil}}
                  end
                end
              end)

            case step do
              {_, _, new_stats, {:violation, name, full_trace}} ->
                {:error, :violation, name, full_trace, new_stats}

              {new_queue, new_visited, new_stats, nil} ->
                do_bfs(new_queue, new_visited, instance_irs, system_ir, invariants, max_depth, max_states, new_stats, relevance, integer_bound, max_queue, symmetry)
            end
        end
    end
  end

  defp fingerprint(state, true), do: Symmetry.canonical_fingerprint(state)
  defp fingerprint(state, _), do: ProductState.fingerprint(state)
end
