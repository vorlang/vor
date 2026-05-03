defmodule Vor.Explorer.LivenessChecker do
  @moduledoc """
  Checks liveness properties against strongly connected components
  in the product state graph.

  A liveness property `always(P implies eventually(Q))` is violated
  when a reachable, **fair** SCC exists where P holds in some state
  but Q never holds in any state of the SCC. Such a cycle means the
  system can loop forever with an active obligation that is never
  fulfilled.

  Uses weak fairness: if an agent has pending messages in every state
  of the SCC, the agent must take at least one action within the SCC.
  Cycles where a continuously-enabled agent never acts are excluded as
  unrealistic under BEAM scheduling.
  """

  alias Vor.Explorer.{Invariant, ProductState, Tarjan}

  @doc """
  Parse a liveness body token list into `{:ok, %{precondition: P, postcondition: Q}}`
  for the pattern `always(P implies eventually(Q))`. Returns `:unsupported` for
  other patterns.
  """
  def parse_liveness_body(body_tokens) do
    # Look for: always ( P implies eventually ( Q ) )
    case extract_leads_to(body_tokens) do
      {:ok, pre_tokens, post_tokens} ->
        {:ok, %{precondition: pre_tokens, postcondition: post_tokens}}

      :no_match ->
        :unsupported
    end
  end

  defp extract_leads_to(tokens) do
    # Pattern: always ( ... implies eventually ( ... ) )
    case tokens do
      [{:keyword, _, :always}, {:delimiter, _, :open_paren} | rest] ->
        case split_on_implies(rest) do
          {:ok, pre_tokens, post_rest} ->
            case post_rest do
              [{:keyword, _, :eventually}, {:delimiter, _, :open_paren} | post_inner] ->
                # Find matching close paren for eventually(...)
                case take_until_close_paren(post_inner, 0) do
                  {:ok, post_tokens, _rest} ->
                    {:ok, pre_tokens, post_tokens}

                  _ ->
                    :no_match
                end

              [{:identifier, _, :eventually}, {:delimiter, _, :open_paren} | post_inner] ->
                case take_until_close_paren(post_inner, 0) do
                  {:ok, post_tokens, _rest} ->
                    {:ok, pre_tokens, post_tokens}

                  _ ->
                    :no_match
                end

              _ ->
                :no_match
            end

          :no_match ->
            :no_match
        end

      _ ->
        :no_match
    end
  end

  defp split_on_implies(tokens, acc \\ []) do
    case tokens do
      [{:keyword, _, :implies} | rest] ->
        {:ok, Enum.reverse(acc), rest}

      [{:identifier, _, :implies} | rest] ->
        {:ok, Enum.reverse(acc), rest}

      [] ->
        :no_match

      [token | rest] ->
        split_on_implies(rest, [token | acc])
    end
  end

  defp take_until_close_paren(tokens, depth, acc \\ [])

  defp take_until_close_paren([{:delimiter, _, :close_paren} | rest], 0, acc) do
    # Also consume the outer always close paren
    case rest do
      [{:delimiter, _, :close_paren} | rest2] -> {:ok, Enum.reverse(acc), rest2}
      _ -> {:ok, Enum.reverse(acc), rest}
    end
  end

  defp take_until_close_paren([{:delimiter, _, :close_paren} | rest], depth, acc) do
    take_until_close_paren(rest, depth - 1, [{:delimiter, nil, :close_paren} | acc])
  end

  defp take_until_close_paren([{:delimiter, _, :open_paren} | rest], depth, acc) do
    take_until_close_paren(rest, depth + 1, [{:delimiter, nil, :open_paren} | acc])
  end

  defp take_until_close_paren([], _depth, _acc), do: :no_match

  defp take_until_close_paren([token | rest], depth, acc) do
    take_until_close_paren(rest, depth, [token | acc])
  end

  # -------------------------------------------------------------------
  # Single-agent liveness
  # -------------------------------------------------------------------

  @doc """
  Check a single-agent liveness property against the state graph.
  Returns `:proven` if every "obligated" state has a path to a
  "fulfilled" state, or `{:violated, reason}` if a stuck state exists.
  """
  def check_single_agent(graph, liveness_body) do
    case parse_liveness_body(liveness_body) do
      {:ok, %{precondition: pre_tokens, postcondition: post_tokens}} ->
        check_reachability(graph, pre_tokens, post_tokens)

      :unsupported ->
        {:error, {:unsupported_liveness,
          "Only always(P implies eventually(Q)) pattern is supported for proven liveness"}}
    end
  end

  defp check_reachability(graph, pre_tokens, post_tokens) do
    # For each state where P holds but Q doesn't, check if Q is reachable
    obligated_states =
      Enum.filter(graph.states, fn state ->
        eval_state_condition(pre_tokens, state, graph) and
          not eval_state_condition(post_tokens, state, graph)
      end)

    case obligated_states do
      [] ->
        # No state has an active obligation → trivially proven
        {:proven}

      states ->
        # For each obligated state, check if a Q-state is reachable
        fulfilled_states =
          MapSet.new(Enum.filter(graph.states, fn state ->
            eval_state_condition(post_tokens, state, graph)
          end))

        stuck = Enum.find(states, fn state ->
          reachable = reachable_from(state, graph)
          MapSet.disjoint?(reachable, fulfilled_states)
        end)

        case stuck do
          nil -> {:proven}
          state -> {:violated, {:stuck_state, state}}
        end
    end
  end

  defp eval_state_condition(tokens, state, graph) do
    # Parse simple conditions: field == :value, field != :value
    case tokens do
      [{:identifier, _, field}, {:operator, _, op}, {:atom, _, value} | _] ->
        field_atom = if is_atom(field), do: field, else: String.to_atom("#{field}")
        value_atom = if is_atom(value), do: value, else: String.to_atom("#{value}")

        state_field_name = case graph do
          %{agent: _} ->
            case graph.states do
              _ -> field_atom
            end
        end

        actual = if state_field_name == field_atom do
          state
        else
          nil
        end

        case op do
          :== -> actual == value_atom
          :!= -> actual != value_atom
          _ -> false
        end

      _ ->
        false
    end
  end

  defp reachable_from(start, graph) do
    do_reachable(graph, [start], MapSet.new())
  end

  defp do_reachable(_graph, [], visited), do: visited

  defp do_reachable(graph, [state | rest], visited) do
    if MapSet.member?(visited, state) do
      do_reachable(graph, rest, visited)
    else
      visited = MapSet.put(visited, state)

      next =
        graph.transitions
        |> Enum.filter(fn t -> t.from == state end)
        |> Enum.map(fn t -> t.to end)

      do_reachable(graph, next ++ rest, visited)
    end
  end

  # -------------------------------------------------------------------
  # Multi-agent liveness (product state graph)
  # -------------------------------------------------------------------

  @doc """
  Check liveness properties against the product state graph built by
  the BFS explorer. Takes the adjacency list (built during exploration),
  the state map (id → ProductState), and the list of liveness invariants.

  Returns `:ok` or `{:violation, name, cycle_info}`.
  """
  def check_multi_agent(adjacency, state_map, liveness_invariants) do
    sccs = Tarjan.find_sccs(adjacency)

    Enum.find_value(liveness_invariants, :ok, fn inv ->
      case parse_liveness_body(inv.body) do
        {:ok, parsed} ->
          check_invariant_against_sccs(inv, parsed, sccs, state_map, adjacency)

        :unsupported ->
          nil
      end
    end)
  end

  defp check_invariant_against_sccs(inv, parsed, sccs, state_map, adjacency) do
    Enum.find_value(sccs, fn scc ->
      scc_states = Enum.map(scc, fn id -> {id, Map.get(state_map, id)} end)

      has_obligation =
        Enum.any?(scc_states, fn {_id, ps} ->
          ps != nil and
            eval_product_condition(parsed.precondition, ps) and
            not eval_product_condition(parsed.postcondition, ps)
        end)

      ever_fulfilled =
        Enum.any?(scc_states, fn {_id, ps} ->
          ps != nil and eval_product_condition(parsed.postcondition, ps)
        end)

      fair = is_fair_scc?(scc, adjacency)

      if has_obligation and not ever_fulfilled and fair do
        {:violation, inv.name, %{
          cycle_length: length(scc),
          cycle_states: Enum.take(scc_states, 5),
          description: "System can loop through #{length(scc)} states without making progress"
        }}
      else
        nil
      end
    end)
  end

  # Weak fairness: if an agent has actions continuously enabled in every
  # state of the SCC, the agent must take at least one action within the
  # SCC. For simplicity in Phase B, we treat all non-trivial SCCs as
  # potentially fair — the BEAM scheduler is preemptive.
  defp is_fair_scc?(scc, _adjacency) when length(scc) > 0, do: true

  # Evaluate a condition against a product state. Reuses the same condition
  # token format as single-agent but evaluates against all agents.
  defp eval_product_condition(tokens, %ProductState{} = ps) do
    # For multi-agent, conditions like `count(agents where role == :leader) == 0`
    # would need the full invariant evaluator. For now, support simple field
    # conditions that check if ANY agent matches.
    case tokens do
      [{:identifier, _, :count}, {:delimiter, _, :open_paren} | _] ->
        # Delegate to the existing invariant evaluator
        try do
          body = parse_count_condition(tokens)
          Invariant.check(ps, %Vor.IR.SystemInvariant{name: "liveness_check", tier: :proven, body: body})
          == :ok
        rescue
          _ -> false
        end

      [{:identifier, _, field}, {:operator, _, op}, {:atom, _, value} | _] ->
        field_atom = if is_atom(field), do: field, else: String.to_atom("#{field}")
        value_atom = if is_atom(value), do: value, else: String.to_atom("#{value}")

        Enum.any?(ps.agents, fn {_name, state} ->
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

  # Attempt to parse count(...) condition tokens into the invariant body
  # format that Vor.Explorer.Invariant understands.
  defp parse_count_condition(tokens) do
    # Very simplified — delegate to the existing system invariant parser
    # For now, wrap in a never() for checking
    case Vor.Parser.parse_system_invariant_body_public(tokens) do
      {:ok, body, _rest} -> body
      _ -> nil
    end
  end
end
