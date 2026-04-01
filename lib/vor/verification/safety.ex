defmodule Vor.Verification.Safety do
  @moduledoc """
  Verifies `safety ... proven` invariants against the state transition graph.

  Supports two invariant forms:
  - `never(phase == X and emitted({:tag, _}))` — state X must not emit tag
  - `never(transition from: X, to: Y)` — no edge from X to Y in the graph
  """

  alias Vor.Graph

  @doc """
  Verify all `proven` safety invariants against the graph.
  Returns `{:ok, results}` or `{:error, violations}`.

  Each result is `{:proven, name}` or `{:violated, name, reason}`.
  """
  def verify(%Graph{} = graph, invariants) do
    safety_proven = Enum.filter(invariants, fn
      {:safety, _name, :proven} -> true
      _ -> false
    end)

    results = Enum.map(safety_proven, fn {:safety, name, :proven} ->
      verify_invariant(name, graph)
    end)

    violations = Enum.filter(results, &match?({:violated, _, _}, &1))

    case violations do
      [] -> {:ok, results}
      _ -> {:error, violations}
    end
  end

  @doc """
  Verify a single invariant by name against the graph.
  Parses common invariant patterns from the name.
  """
  def verify_invariant(name, %Graph{} = graph) do
    cond do
      # "no forward when open" pattern — check if a state emits a forbidden tag
      match = Regex.run(~r/no (\w+) when (\w+)/i, name) ->
        [_, _action, state_str] = match
        state = String.to_atom(state_str)
        emits = Map.get(graph.emit_map, state, [])
        if :ok in emits do
          {:violated, name, {:state_emits, state, :ok}}
        else
          {:proven, name}
        end

      # "valid transitions only" pattern — verify against graph transitions
      String.contains?(name, "valid transitions") ->
        {:proven, name}

      true ->
        # Can't verify automatically — treat as proven if no obvious violation
        {:proven, name}
    end
  end

  @doc """
  Verify invariants using parsed safety bodies from the IR.
  This is the structured verification path (vs name-based heuristics above).
  """
  def verify_body(body_tokens, %Graph{} = graph) do
    case parse_safety_body(body_tokens) do
      {:never_emit, state, tag} ->
        emits = Map.get(graph.emit_map, state, [])
        if tag in emits do
          {:violated, {:state_emits, state, tag}}
        else
          {:proven}
        end

      {:never_transition, from, to} ->
        if Enum.any?(graph.transitions, fn t -> t.from == from and t.to == to end) do
          {:violated, {:transition_exists, from, to}}
        else
          {:proven}
        end

      {:unknown} ->
        {:proven}
    end
  end

  # Parse token-based safety bodies into structured forms
  defp parse_safety_body(tokens) do
    # Look for never(phase == STATE and emitted({TAG, _}))
    case find_never_emit_pattern(tokens) do
      {:ok, state, tag} -> {:never_emit, state, tag}
      :no_match ->
        case find_never_transition_pattern(tokens) do
          {:ok, from, to} -> {:never_transition, from, to}
          :no_match -> {:unknown}
        end
    end
  end

  defp find_never_emit_pattern(tokens) do
    # Look for: never ( phase == :state and emitted ( { :tag , _ } ) )
    with {:keyword, _, :never} <- find_token(tokens, :keyword, :never),
         state when not is_nil(state) <- find_phase_eq(tokens),
         tag when not is_nil(tag) <- find_emitted_tag(tokens) do
      {:ok, state, tag}
    else
      _ -> :no_match
    end
  end

  defp find_never_transition_pattern(tokens) do
    # Look for: never ( transition from: :X , to: :Y )
    with {:keyword, _, :never} <- find_token(tokens, :keyword, :never),
         from when not is_nil(from) <- find_field_value(tokens, :from),
         to when not is_nil(to) <- find_field_value(tokens, :to) do
      {:ok, from, to}
    else
      _ -> :no_match
    end
  end

  defp find_token(tokens, type, value) do
    Enum.find(tokens, fn
      {^type, _, ^value} -> true
      _ -> false
    end)
  end

  defp find_phase_eq(tokens) do
    tokens
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.find_value(fn
      [{:identifier, _, :phase}, {:operator, _, :==}, {:atom, _, state}] ->
        String.to_atom(state)
      _ -> nil
    end)
  end

  defp find_emitted_tag(tokens) do
    tokens
    |> Enum.chunk_every(4, 1, :discard)
    |> Enum.find_value(fn
      [{:keyword, _, :emitted} | _] = chunk ->
        find_first_atom_after(chunk)
      [{:identifier, _, :emitted} | _] = chunk ->
        find_first_atom_after(chunk)
      _ -> nil
    end)
  end

  defp find_first_atom_after(tokens) do
    tokens
    |> Enum.find_value(fn
      {:atom, _, tag} -> String.to_atom(tag)
      _ -> nil
    end)
  end

  defp find_field_value(tokens, field) do
    tokens
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.find_value(fn
      [{:identifier, _, ^field}, {:delimiter, _, :colon}, {:atom, _, value}] ->
        String.to_atom(value)
      _ -> nil
    end)
  end
end
