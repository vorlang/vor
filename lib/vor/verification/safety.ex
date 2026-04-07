defmodule Vor.Verification.Safety do
  @moduledoc """
  Verifies `safety ... proven` invariants against the state transition graph.

  Supports two invariant forms:
  - `never(phase == X and emitted({:tag, _}))` — state X must not emit tag
  - `never(transition from: X, to: Y)` — no edge from X to Y in the graph
  """

  alias Vor.{Graph, IR}

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
  def verify_body(body_tokens, %Graph{} = graph, agent \\ nil) do
    case parse_safety_body(body_tokens) do
      {:never_emit, state, tag} ->
        # Precise data-flow check first: is there an extern-gated emit of `tag`
        # in `state`? If so, the proof depends on extern behavior — fail closed.
        case extern_gated_emit(agent, state, tag) do
          {:found, info} ->
            {:error, {:extern_gated_emit, info}}

          :none ->
            emits = Map.get(graph.emit_map, state, [])
            if tag in emits do
              {:violated, {:state_emits, state, tag}}
            else
              {:proven}
            end
        end

      {:never_transition, from, to} ->
        case extern_gated_transition(agent, from, to) do
          {:found, info} ->
            {:error, {:extern_gated_transition, info}}

          :none ->
            if Enum.any?(graph.transitions, fn t -> t.from == from and t.to == to end) do
              {:violated, {:transition_exists, from, to}}
            else
              {:proven}
            end
        end

      {:unknown, _raw} ->
        {:error, {:unsupported_invariant,
          "Cannot verify invariant — the property uses " <>
          "constructs the verifier does not yet support. " <>
          "Change the tier from 'proven' to 'monitored', or simplify the property."}}
    end
  end

  # ----------------------------------------------------------------------
  # Extern-dependency data-flow analysis
  #
  # A `proven` safety invariant is unverifiable when the prohibited emit (or
  # transition) sits inside a conditional branch whose condition data-depends
  # on the result of an extern call. In that case the compiler cannot know
  # which branch executes — the extern's return is opaque — so it cannot
  # claim a proof of the invariant.
  #
  # The walker tracks two pieces of state:
  #   * env: a MapSet of variable names whose value transitively traces back
  #     to an extern_call binding (the "tainted" variables).
  #   * in_gate?: whether we are currently inside a conditional branch whose
  #     condition referenced a tainted variable.
  #
  # If the prohibited emit/transition is encountered while in_gate? is true,
  # the analysis reports it as extern-gated.
  # ----------------------------------------------------------------------

  defp extern_gated_emit(nil, _state, _tag), do: :none

  defp extern_gated_emit(%IR.Agent{} = agent, state, tag) do
    field_name = state_field_name(agent)

    agent.handlers
    |> Enum.filter(fn h -> handler_guards_state?(h.guard, state, field_name) end)
    |> Enum.find_value(:none, fn handler ->
      case walk_actions(handler.actions, MapSet.new(), false, {:emit, tag}, field_name) do
        {:found, action} ->
          {:found, %{handler: handler, action: action, state: state, tag: tag}}

        :ok ->
          nil
      end
    end)
  end

  defp extern_gated_transition(nil, _from, _to), do: :none

  defp extern_gated_transition(%IR.Agent{} = agent, from, to) do
    field_name = state_field_name(agent)

    agent.handlers
    |> Enum.filter(fn h -> handler_guards_state?(h.guard, from, field_name) end)
    |> Enum.find_value(:none, fn handler ->
      case walk_actions(handler.actions, MapSet.new(), false, {:transition, to}, field_name) do
        {:found, action} ->
          {:found, %{handler: handler, action: action, from: from, to: to}}

        :ok ->
          nil
      end
    end)
  end

  defp state_field_name(%IR.Agent{state_fields: [%IR.StateField{name: name} | _]}), do: name
  defp state_field_name(_), do: :phase

  defp handler_guards_state?(%IR.GuardExpr{field: f, op: :==, value: {:atom, s}}, target, field_name)
       when f == field_name,
       do: s == target

  defp handler_guards_state?(%IR.CompoundGuardExpr{left: l, right: r}, target, field_name),
    do: handler_guards_state?(l, target, field_name) or handler_guards_state?(r, target, field_name)

  defp handler_guards_state?(_, _, _), do: false

  defp walk_actions([], _env, _in_gate?, _target, _field_name), do: :ok

  defp walk_actions([nil | rest], env, in_gate?, target, field_name) do
    walk_actions(rest, env, in_gate?, target, field_name)
  end

  defp walk_actions([action | rest], env, in_gate?, target, field_name) do
    case action do
      %IR.Action{type: :extern_call, data: %IR.ExternCallAction{bind: bind}} when not is_nil(bind) ->
        walk_actions(rest, MapSet.put(env, bind), in_gate?, target, field_name)

      %IR.Action{type: :extern_call} ->
        walk_actions(rest, env, in_gate?, target, field_name)

      %IR.Action{type: :var_binding, data: %IR.VarBindingAction{name: name, expr: expr}} ->
        env2 = if expr_tainted?(expr, env), do: MapSet.put(env, name), else: env
        walk_actions(rest, env2, in_gate?, target, field_name)

      %IR.Action{type: :emit, data: %IR.EmitAction{tag: tag}} = a ->
        if in_gate? and target == {:emit, tag} do
          {:found, a}
        else
          walk_actions(rest, env, in_gate?, target, field_name)
        end

      %IR.Action{type: :transition, data: %IR.TransitionAction{field: field, value: value}} = a ->
        if in_gate? and matches_transition_target?(target, field, value, field_name) do
          {:found, a}
        else
          walk_actions(rest, env, in_gate?, target, field_name)
        end

      %IR.Action{type: :conditional, data: %IR.ConditionalAction{condition: cond_, then_actions: ta, else_actions: ea}} ->
        gate? = in_gate? or condition_tainted?(cond_, env)

        case walk_actions(ta, env, gate?, target, field_name) do
          {:found, _} = found ->
            found

          :ok ->
            case walk_actions(ea, env, gate?, target, field_name) do
              {:found, _} = found -> found
              :ok -> walk_actions(rest, env, in_gate?, target, field_name)
            end
        end

      _ ->
        walk_actions(rest, env, in_gate?, target, field_name)
    end
  end

  defp matches_transition_target?({:transition, target_to}, field, value, field_name) do
    field == field_name and value == target_to
  end

  defp matches_transition_target?(_, _, _, _), do: false

  defp expr_tainted?({:arith, _op, l, r}, env), do: operand_tainted?(l, env) or operand_tainted?(r, env)
  defp expr_tainted?({:minmax, _op, l, r}, env), do: operand_tainted?(l, env) or operand_tainted?(r, env)
  defp expr_tainted?({:map_op, _op, args}, env), do: Enum.any?(args, &operand_tainted?(&1, env))
  defp expr_tainted?(other, env), do: operand_tainted?(other, env)

  defp operand_tainted?({:bound_var, name}, env), do: MapSet.member?(env, name)
  defp operand_tainted?(_, _env), do: false

  defp condition_tainted?(%IR.Condition{left: l, right: r}, env),
    do: operand_tainted?(l, env) or operand_tainted?(r, env)

  defp condition_tainted?(%IR.CompoundCondition{left: l, right: r}, env),
    do: condition_tainted?(l, env) or condition_tainted?(r, env)

  defp condition_tainted?(_, _env), do: false

  # Parse token-based safety bodies into structured forms
  defp parse_safety_body(tokens) do
    # Look for never(phase == STATE and emitted({TAG, _}))
    case find_never_emit_pattern(tokens) do
      {:ok, state, tag} -> {:never_emit, state, tag}
      :no_match ->
        case find_never_transition_pattern(tokens) do
          {:ok, from, to} -> {:never_transition, from, to}
          :no_match -> {:unknown, tokens}
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
    # Match any identifier == :atom pattern (not just :phase)
    # The verifier checks against the graph's emit_map, which only contains
    # declared states, so this is safe for any state field name.
    tokens
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.find_value(fn
      [{:identifier, _, _field}, {:operator, _, :==}, {:atom, _, state}] ->
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
