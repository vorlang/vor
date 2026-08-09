defmodule Vor.Explorer.LivenessChecker do
  @moduledoc """
  Liveness body parsing (`parse_liveness_body/1`) and the **single-agent**
  compile-time liveness check (`check_single_agent/2`) for
  `always(P implies eventually(Q))`.

  Multi-agent (system-tier) liveness lives in `Vor.Explorer.run_liveness_check/2`,
  which fails closed on detected violations (terminal deadlock sinks and
  non-progress cycles) and refuses conditions it cannot evaluate. An earlier
  `check_multi_agent/3` duplicate here returned `false` for anything it couldn't
  evaluate (the F10 silent-false) and had no callers; it was removed so it can't
  be re-wired by mistake.
  """

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
end
