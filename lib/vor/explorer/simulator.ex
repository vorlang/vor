defmodule Vor.Explorer.Simulator do
  @moduledoc """
  Symbolic simulation of an agent handler against the explorer's product
  state. Given an `IR.Handler`, the agent's current tracked state, an
  incoming message, and the system's connection topology, the simulator
  produces one or more `{new_agent_state, outgoing_messages}` results.

  The simulator interprets the existing IR action tree directly. There is no
  separate "transition table" representation — the IR is already declarative
  enough.

  Symbolic values:

  * concrete values (integers, atoms, lists, maps) are tracked precisely.
  * results of extern calls and any expression that depends on them are
    represented as `:unknown`. When a conditional branches on `:unknown` the
    simulator returns BOTH the then- and else-results — the model checker
    explores both possibilities. This implements the conservative
    over-approximation described in the design doc.

  Phase 1 supports the action types used by the existing `.vor` examples:
  pattern bindings, var bindings (literals/variables/arithmetic/min-max),
  transitions, emits, sends, broadcasts, conditionals, extern calls (treated
  as unknowns), and noop. Other action types are passed through as no-ops.
  """

  alias Vor.IR

  @type agent_state :: %{atom() => term()}
  @type pending_message :: {atom(), atom(), {atom(), map()}}
  @type result :: {agent_state(), [pending_message()]}

  @doc """
  Simulate `handler` for agent `agent_name` receiving `msg` while in
  `agent_state`. Returns a list of possible `{new_state, outgoing_messages}`
  results — one for each path through the handler's conditionals.

  `msg` must be a `{tag, fields_map}` tuple. `connections` is a list of
  `agent_name` atoms reachable from `agent_name` via the system's `connect`
  topology — used by `broadcast`.
  """
  def simulate(%IR.Handler{} = handler, agent_state, {_tag, msg_fields} = _msg, agent_name, connections)
      when is_map(agent_state) do
    env = bind_pattern(handler.pattern, msg_fields, agent_state)
    initial = {agent_state, [], env}

    # Walk handler actions, accumulating result branches.
    walk(handler.actions, [initial], agent_name, connections)
    |> Enum.map(fn {state, msgs, _env} -> {state, Enum.reverse(msgs)} end)
    |> dedupe_results()
  end

  @doc """
  True iff `handler.guard` matches `agent_state` and `msg_fields`. A `nil`
  guard always matches. Unknowns evaluate to `true` (conservative — the model
  checker treats them as potentially-applicable so it explores them).
  """
  def guard_matches?(%IR.Handler{guard: nil}, _agent_state, _msg_fields), do: true

  def guard_matches?(%IR.Handler{guard: guard, pattern: pattern}, agent_state, msg_fields) do
    env = bind_pattern(pattern, msg_fields, agent_state)
    eval_guard(guard, agent_state, env) != false
  end

  # ----------------------------------------------------------------------
  # Pattern binding
  # ----------------------------------------------------------------------

  defp bind_pattern(%IR.MatchPattern{bindings: bindings}, msg_fields, _agent_state)
       when is_map(msg_fields) do
    Enum.reduce(bindings, %{}, fn
      %IR.Binding{name: {:literal, _}}, acc ->
        acc

      %IR.Binding{name: name, field: field}, acc ->
        field_atom = if is_atom(field), do: field, else: String.to_atom("#{field}")
        Map.put(acc, name, Map.get(msg_fields, field_atom, :unknown))
    end)
  end

  defp bind_pattern(_, _msg_fields, _state), do: %{}

  # ----------------------------------------------------------------------
  # Action walker — fans out branches at conditionals
  # ----------------------------------------------------------------------

  defp walk([], branches, _agent_name, _connections), do: branches

  defp walk([nil | rest], branches, agent_name, connections),
    do: walk(rest, branches, agent_name, connections)

  defp walk([action | rest], branches, agent_name, connections) do
    new_branches =
      Enum.flat_map(branches, fn branch ->
        step(action, branch, agent_name, connections)
      end)

    walk(rest, new_branches, agent_name, connections)
  end

  # Step a single action against a single branch. Returns one or more
  # branches (multiple only for conditionals on unknown conditions).

  defp step(%IR.Action{type: :var_binding, data: %IR.VarBindingAction{name: name, expr: expr}},
           {state, msgs, env}, _an, _conn) do
    [{state, msgs, Map.put(env, name, eval_expr(expr, state, env))}]
  end

  defp step(%IR.Action{type: :extern_call, data: %IR.ExternCallAction{bind: bind}},
           {state, msgs, env}, _an, _conn) do
    case bind do
      nil -> [{state, msgs, env}]
      name -> [{state, msgs, Map.put(env, name, :unknown)}]
    end
  end

  defp step(%IR.Action{type: :transition, data: %IR.TransitionAction{field: field, value: value}},
           {state, msgs, env}, _an, _conn) do
    new_value = eval_value_ref(value, state, env)
    [{Map.put(state, field, new_value), msgs, Map.put(env, field, new_value)}]
  end

  defp step(%IR.Action{type: :emit}, branch, _an, _conn) do
    # Emits are replies to the synchronous caller. They do not affect the
    # product state — only `send`/`broadcast` enqueue inter-agent messages.
    [branch]
  end

  defp step(%IR.Action{type: :send, data: %IR.SendAction{target: target, tag: tag, fields: fields}},
           {state, msgs, env}, agent_name, _conn) do
    target_atom = resolve_target(target, env)
    msg = {tag, eval_fields(fields, state, env)}
    [{state, [{agent_name, target_atom, msg} | msgs], env}]
  end

  defp step(%IR.Action{type: :broadcast, data: %IR.BroadcastAction{tag: tag, fields: fields}},
           {state, msgs, env}, agent_name, connections) do
    payload = {tag, eval_fields(fields, state, env)}
    new_msgs = Enum.reduce(connections, msgs, fn target, acc ->
      [{agent_name, target, payload} | acc]
    end)
    [{state, new_msgs, env}]
  end

  defp step(%IR.Action{type: :conditional, data: %IR.ConditionalAction{condition: cond_, then_actions: ta, else_actions: ea}},
           {state, msgs, env} = branch, agent_name, connections) do
    case eval_condition(cond_, state, env) do
      true ->
        walk(ta, [branch], agent_name, connections)

      false ->
        walk(ea, [branch], agent_name, connections)

      :unknown ->
        # Branch out — explore both
        walk(ta, [branch], agent_name, connections) ++
          walk(ea, [{state, msgs, env}], agent_name, connections)
    end
  end

  # Phase-1 unsupported actions are passed through as no-ops.
  defp step(_other, branch, _an, _conn), do: [branch]

  # ----------------------------------------------------------------------
  # Expression / value / condition evaluation
  # ----------------------------------------------------------------------

  defp eval_expr({:arith, op, left, right}, state, env) do
    apply_arith(op, eval_value_ref(left, state, env), eval_value_ref(right, state, env))
  end

  defp eval_expr({:minmax, op, left, right}, state, env) do
    l = eval_value_ref(left, state, env)
    r = eval_value_ref(right, state, env)
    cond do
      l == :unknown or r == :unknown -> :unknown
      op == :min -> min(l, r)
      op == :max -> max(l, r)
    end
  end

  defp eval_expr({:map_op, _op, _args}, _state, _env), do: :unknown

  defp eval_expr({:integer, n}, _state, _env), do: n
  defp eval_expr({:atom, a}, _state, _env), do: a

  defp eval_expr(other, state, env), do: eval_value_ref(other, state, env)

  defp eval_value_ref({:bound_var, name}, _state, env), do: Map.get(env, name, :unknown)
  defp eval_value_ref({:param, name}, state, env) do
    case Map.fetch(env, name) do
      {:ok, v} -> v
      :error -> Map.get(state, name, :unknown)
    end
  end
  defp eval_value_ref({:integer, n}, _state, _env), do: n
  defp eval_value_ref({:atom, a}, _state, _env), do: a
  defp eval_value_ref({:arith, _, _, _} = e, state, env), do: eval_expr(e, state, env)
  defp eval_value_ref({:minmax, _, _, _} = e, state, env), do: eval_expr(e, state, env)
  defp eval_value_ref({:list, items}, state, env), do: Enum.map(items || [], &eval_value_ref(&1, state, env))
  defp eval_value_ref(value, _state, _env) when is_atom(value) or is_integer(value) or is_binary(value),
    do: value
  defp eval_value_ref(_, _state, _env), do: :unknown

  defp apply_arith(_op, :unknown, _), do: :unknown
  defp apply_arith(_op, _, :unknown), do: :unknown
  defp apply_arith(op, l, r) when op in [:+, :plus] and is_integer(l) and is_integer(r), do: l + r
  defp apply_arith(op, l, r) when op in [:-, :minus] and is_integer(l) and is_integer(r), do: l - r
  defp apply_arith(op, l, r) when op in [:*, :star] and is_integer(l) and is_integer(r), do: l * r
  defp apply_arith(op, l, r) when op in [:/, :slash] and is_integer(l) and is_integer(r) and r != 0, do: div(l, r)
  defp apply_arith(_, _, _), do: :unknown

  defp eval_condition(%IR.Condition{left: l, op: op, right: r}, state, env) do
    apply_cmp(op, eval_value_ref(l, state, env), eval_value_ref(r, state, env))
  end

  defp eval_condition(%IR.CompoundCondition{op: :and, left: l, right: r}, state, env) do
    case {eval_condition(l, state, env), eval_condition(r, state, env)} do
      {true, true} -> true
      {false, _} -> false
      {_, false} -> false
      _ -> :unknown
    end
  end

  defp eval_condition(%IR.CompoundCondition{op: :or, left: l, right: r}, state, env) do
    case {eval_condition(l, state, env), eval_condition(r, state, env)} do
      {true, _} -> true
      {_, true} -> true
      {false, false} -> false
      _ -> :unknown
    end
  end

  defp eval_condition(_, _, _), do: :unknown

  defp eval_guard(nil, _state, _env), do: true

  defp eval_guard(%IR.GuardExpr{field: field, op: op, value: value}, state, env) do
    actual = Map.get(env, field, Map.get(state, field, :unknown))
    expected = case value do
      {:atom, a} when is_binary(a) -> String.to_atom(a)
      {:atom, a} -> a
      {:integer, n} -> n
      other -> eval_value_ref(other, state, env)
    end
    apply_cmp(op, actual, expected)
  end

  defp eval_guard(%IR.CompoundGuardExpr{op: :and, left: l, right: r}, state, env) do
    case {eval_guard(l, state, env), eval_guard(r, state, env)} do
      {true, true} -> true
      {false, _} -> false
      {_, false} -> false
      _ -> :unknown
    end
  end

  defp eval_guard(%IR.CompoundGuardExpr{op: :or, left: l, right: r}, state, env) do
    case {eval_guard(l, state, env), eval_guard(r, state, env)} do
      {true, _} -> true
      {_, true} -> true
      {false, false} -> false
      _ -> :unknown
    end
  end

  defp eval_guard(_, _, _), do: :unknown

  defp apply_cmp(_, :unknown, _), do: :unknown
  defp apply_cmp(_, _, :unknown), do: :unknown
  defp apply_cmp(:==, a, b), do: a == b
  defp apply_cmp(:!=, a, b), do: a != b
  defp apply_cmp(:>, a, b) when is_integer(a) and is_integer(b), do: a > b
  defp apply_cmp(:<, a, b) when is_integer(a) and is_integer(b), do: a < b
  defp apply_cmp(:>=, a, b) when is_integer(a) and is_integer(b), do: a >= b
  defp apply_cmp(:<=, a, b) when is_integer(a) and is_integer(b), do: a <= b
  defp apply_cmp(_, _, _), do: :unknown

  # ----------------------------------------------------------------------
  # Field evaluation for emit/send/broadcast
  # ----------------------------------------------------------------------

  defp eval_fields(fields, state, env) do
    Enum.into(fields, %{}, fn
      {field, value} ->
        {field, eval_value_ref(value, state, env)}
    end)
  end

  defp resolve_target({:bound_var, name}, env), do: Map.get(env, name, :unknown)
  defp resolve_target({:param, name}, env), do: Map.get(env, name, :unknown)
  defp resolve_target(name, _env) when is_atom(name), do: name
  defp resolve_target(_, _env), do: :unknown

  defp dedupe_results(results), do: Enum.uniq(results)
end
