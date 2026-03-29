defmodule Vor.Lowering do
  @moduledoc """
  Transforms Vor AST into the Core IR.
  Resolves agent behaviour, module names, variable bindings.
  """

  alias Vor.{AST, IR}

  def lower(%AST.Agent{} = ast) do
    state_fields = extract_state_fields(ast.body)
    has_state = state_fields != []

    ir = %IR.Agent{
      name: ast.name,
      module: Module.concat([Vor, Agent, ast.name]),
      behaviour: if(has_state, do: :gen_statem, else: :gen_server),
      state_fields: state_fields,
      protocol: extract_protocol(ast.body),
      handlers: extract_handlers(ast.body),
      relations: extract_relations(ast.body),
      invariants: extract_invariants(ast.body),
      resilience: nil
    }

    {:ok, ir}
  end

  # Coerce string or atom to atom
  defp to_atom(v) when is_atom(v), do: v
  defp to_atom(v) when is_binary(v), do: String.to_atom(v)

  defp extract_state_fields(body) do
    body
    |> Enum.filter(&match?(%AST.StateDecl{}, &1))
    |> Enum.map(fn %AST.StateDecl{field: field, type_union: types} ->
      %IR.StateField{name: to_atom(field), values: Enum.map(types, &to_atom/1), initial: to_atom(List.first(types))}
    end)
  end

  defp extract_protocol(body) do
    case Enum.find(body, &match?(%AST.Protocol{}, &1)) do
      nil ->
        %IR.Protocol{accepts: [], emits: []}

      %AST.Protocol{accepts: accepts, emits: emits} ->
        %IR.Protocol{
          accepts: Enum.map(accepts, &lower_message_spec/1),
          emits: Enum.map(emits, &lower_message_spec/1)
        }
    end
  end

  defp lower_message_spec(%AST.MessageSpec{tag: tag, fields: fields}) do
    %IR.MessageType{
      tag: to_atom(tag),
      fields: Enum.map(fields, fn {name, type} -> {to_atom(name), to_atom(type)} end)
    }
  end

  defp extract_handlers(body) do
    body
    |> Enum.filter(&match?(%AST.Handler{}, &1))
    |> Enum.map(&lower_handler/1)
  end

  defp lower_handler(%AST.Handler{pattern: pattern, guard: guard, body: body}) do
    %IR.Handler{
      pattern: lower_pattern(pattern),
      guard: lower_guard(guard),
      actions: Enum.map(body, &lower_action/1)
    }
  end

  defp lower_pattern(%AST.Pattern{tag: tag, bindings: bindings}) do
    %IR.MatchPattern{
      tag: to_atom(tag),
      bindings: Enum.map(bindings, fn
        {field, {:var, var}} ->
          %IR.Binding{name: to_atom(var), field: to_atom(field)}
        {field, {:atom, value}} ->
          %IR.Binding{name: {:literal, to_atom(value)}, field: to_atom(field)}
        {_field, :wildcard} ->
          nil
      end)
      |> Enum.reject(&is_nil/1)
    }
  end

  defp lower_guard(nil), do: nil

  defp lower_guard(%AST.Guard{field: field, op: op, value: value}) do
    %IR.GuardExpr{
      field: to_atom(field),
      op: op,
      value: lower_guard_value(value)
    }
  end

  defp lower_guard(%AST.CompoundGuard{op: op, left: left, right: right}) do
    %IR.CompoundGuardExpr{
      op: op,
      left: lower_guard(left),
      right: lower_guard(right)
    }
  end

  defp lower_guard_value({:atom, v}), do: {:atom, to_atom(v)}
  defp lower_guard_value({:var, v}), do: {:var, to_atom(v)}
  defp lower_guard_value({:range, low, high}), do: {:range, low, high}
  defp lower_guard_value(other), do: other

  defp lower_action(%AST.Emit{tag: tag, fields: fields}) do
    %IR.Action{
      type: :emit,
      data: %IR.EmitAction{
        tag: to_atom(tag),
        fields: Enum.map(fields, fn
          {field, {:var, var}} -> {to_atom(field), {:bound_var, to_atom(var)}}
          {field, {:atom, val}} -> {to_atom(field), {:atom, to_atom(val)}}
        end)
      }
    }
  end

  defp lower_action(%AST.Transition{field: field, value: value}) do
    %IR.Action{
      type: :transition,
      data: %IR.TransitionAction{
        field: to_atom(field),
        value: to_atom(value)
      }
    }
  end

  defp lower_action(%AST.StartTimer{name: name}) do
    %IR.Action{
      type: :start_timer,
      data: %IR.TimerAction{op: :start, name: to_atom(name), args: []}
    }
  end

  defp lower_action(%AST.CancelTimer{name: name}) do
    %IR.Action{
      type: :cancel_timer,
      data: %IR.TimerAction{op: :cancel, name: to_atom(name), args: []}
    }
  end

  defp lower_action(%AST.RestartTimer{name: name, args: args}) do
    %IR.Action{
      type: :restart_timer,
      data: %IR.TimerAction{op: :restart, name: to_atom(name), args: args}
    }
  end

  defp lower_action(%AST.FunctionCall{name: name, args: args}) do
    %IR.Action{
      type: :function_call,
      data: %IR.FunctionCallAction{name: to_atom(name), args: args}
    }
  end

  defp extract_relations(body) do
    body
    |> Enum.filter(&match?(%AST.Relation{}, &1))
    |> Enum.map(fn %AST.Relation{name: name, params: params, facts: facts} ->
      %IR.Relation{
        name: to_atom(name),
        params: Enum.map(params, fn {n, t} -> {to_atom(n), to_atom(t)} end),
        facts: Enum.map(facts, fn %AST.Fact{fields: fields} ->
          Enum.map(fields, fn {k, v} -> {to_atom(k), lower_fact_value(v)} end)
        end)
      }
    end)
  end

  defp lower_fact_value({:atom, v}), do: {:atom, to_atom(v)}
  defp lower_fact_value({:integer, v}), do: {:integer, v}
  defp lower_fact_value({:multiply, a, b}), do: {:multiply, lower_fact_value(a), lower_fact_value(b)}
  defp lower_fact_value(other), do: other

  defp extract_invariants(body) do
    safety =
      body
      |> Enum.filter(&match?(%AST.Safety{}, &1))
      |> Enum.map(fn %AST.Safety{name: name, tier: tier} -> {:safety, name, tier} end)

    liveness =
      body
      |> Enum.filter(&match?(%AST.Liveness{}, &1))
      |> Enum.map(fn %AST.Liveness{name: name, tier: tier} -> {:liveness, name, tier} end)

    safety ++ liveness
  end
end
