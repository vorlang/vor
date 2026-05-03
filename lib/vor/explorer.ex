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

  alias Vor.Explorer.{Invariant, LivenessChecker, ProductState, Relevance, Successor, Symmetry, Tarjan}
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

    # Split safety and liveness invariants
    safety_invariants = Enum.filter(invariants, fn inv -> Map.get(inv, :kind, :safety) == :safety end)
    liveness_invariants = Enum.filter(invariants, fn inv -> inv.kind == :liveness and inv.tier == :proven end)

    symmetry = Symmetry.enabled?(system_ir, safety_invariants, symmetry_opt)

    relevance = Relevance.compute(system_ir, instance_irs, safety_invariants ++ liveness_invariants)

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

    case check_all_invariants(initial, safety_invariants) do
      {:violation, name} ->
        {:error, :violation, name, [initial], base_stats}

      :ok ->
        bfs_result = bfs(initial, instance_irs, system_ir, safety_invariants, max_depth, max_states,
          relevance, integer_bound, max_queue, symmetry)

        # Post-processing: liveness checking via Tarjan's SCC
        case bfs_result do
          {:ok, status, stats} when liveness_invariants != [] ->
            liveness_result = run_liveness_check(stats, liveness_invariants)
            {:ok, status, Map.put(stats, :liveness, liveness_result)}

          other ->
            other
        end
    end
  end

  defp run_liveness_check(%{adjacency: adjacency, state_map: state_map}, liveness_invariants)
       when is_map(adjacency) and map_size(adjacency) > 0 do
    sccs = Tarjan.find_sccs(adjacency)

    results =
      Enum.map(liveness_invariants, fn inv ->
        case LivenessChecker.parse_liveness_body(inv.body) do
          {:ok, parsed} ->
            # Check SCCs (cycles) first
            cycle_result = check_liveness_inv(inv, parsed, sccs, state_map)

            case cycle_result do
              {:ok, _} ->
                # Also check terminal states (dead ends with active obligations)
                check_terminal_liveness(inv, parsed, adjacency, state_map)
              violation ->
                violation
            end

          :unsupported ->
            {:unsupported, inv.name}
        end
      end)

    %{sccs_checked: length(sccs), results: results}
  end

  defp run_liveness_check(_stats, _invariants), do: %{sccs_checked: 0, results: []}

  # Check if any terminal state (no outgoing edges) has an active obligation
  defp check_terminal_liveness(inv, parsed, adjacency, state_map) do
    terminal_violation =
      Enum.find_value(adjacency, fn {state_fp, successors} ->
        if successors == [] or Enum.all?(successors, &(&1 == state_fp)) do
          case Map.get(state_map, state_fp) do
            nil -> nil
            ps ->
              obligated = eval_liveness_condition(parsed.precondition, ps)
              fulfilled = eval_liveness_condition(parsed.postcondition, ps)

              if obligated and not fulfilled do
                {:violation, inv.name, %{cycle_length: 1, description: "Terminal state with unfulfilled obligation"}}
              end
          end
        end
      end)

    terminal_violation || {:ok, inv.name}
  end

  defp check_liveness_inv(inv, parsed, sccs, state_map) do
    violation =
      Enum.find_value(sccs, fn scc ->
        scc_states = Enum.map(scc, fn id -> {id, Map.get(state_map, id)} end)

        has_obligation =
          Enum.any?(scc_states, fn {_id, ps} ->
            ps != nil and
              eval_liveness_condition(parsed.precondition, ps) and
              not eval_liveness_condition(parsed.postcondition, ps)
          end)

        ever_fulfilled =
          Enum.any?(scc_states, fn {_id, ps} ->
            ps != nil and eval_liveness_condition(parsed.postcondition, ps)
          end)

        if has_obligation and not ever_fulfilled do
          {:violation, inv.name, %{cycle_length: length(scc)}}
        end
      end)

    violation || {:ok, inv.name}
  end

  # Evaluate a simple liveness condition (field == :value or field != :value)
  # against a product state. Checks if ANY agent matches.
  defp eval_liveness_condition(tokens, %ProductState{agents: agents}) do
    case tokens do
      [{:identifier, _, field}, {:operator, _, op}, {:atom, _, value} | _] ->
        field_atom = if is_atom(field), do: field, else: String.to_atom("#{field}")
        value_atom = if is_atom(value), do: value, else: String.to_atom("#{value}")

        Enum.any?(agents, fn {_name, state} ->
          actual = Map.get(state, field_atom)
          case op do
            :== -> actual == value_atom
            :!= -> actual != value_atom
            _ -> false
          end
        end)

      _ ->
        false
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
    initial_fp = fingerprint(initial, symmetry)
    queue = :queue.in({initial, [initial], initial_fp}, :queue.new())
    visited = MapSet.new([initial_fp])
    stats = %{
      states_explored: 1,
      max_depth_reached: 0,
      relevance: relevance,
      integer_bound: integer_bound,
      max_queue: max_queue,
      symmetry: symmetry,
      adjacency: %{initial_fp => []},
      state_map: %{initial_fp => initial}
    }

    do_bfs(queue, visited, instance_irs, system_ir, invariants, max_depth, max_states, stats, relevance, integer_bound, max_queue, symmetry)
  end

  defp do_bfs(queue, visited, instance_irs, system_ir, invariants, max_depth, max_states, stats, relevance, integer_bound, max_queue, symmetry) do
    case :queue.out(queue) do
      {:empty, _} ->
        {:ok, :proven, stats}

      {{:value, {state, trace, state_fp}}, rest} ->
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

                # Track adjacency edge regardless of visited status
                s = update_in(s, [:adjacency], fn adj ->
                  Map.update(adj || %{}, state_fp, [fp], fn existing -> [fp | existing] end)
                end)

                if MapSet.member?(v, fp) do
                  {:cont, {q, v, s, nil}}
                else
                  new_visited = MapSet.put(v, fp)
                  new_stats = %{
                    s
                    | states_explored: s.states_explored + 1,
                      max_depth_reached: max(s.max_depth_reached, succ.depth)
                  }

                  # Track state map and init adjacency entry
                  new_stats = put_in(new_stats, [:state_map, fp], succ)
                  new_stats = update_in(new_stats, [:adjacency], fn adj ->
                    Map.put_new(adj || %{}, fp, [])
                  end)

                  case check_all_invariants(succ, invariants) do
                    {:violation, name} ->
                      {:halt, {q, new_visited, new_stats, {:violation, name, trace ++ [succ]}}}

                    :ok ->
                      new_q = :queue.in({succ, trace ++ [succ], fp}, q)
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
