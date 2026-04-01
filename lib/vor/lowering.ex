defmodule Vor.Lowering do
  @moduledoc """
  Transforms Vor AST into the Core IR.
  Resolves agent behaviour, module names, variable bindings.
  """

  alias Vor.{AST, IR}

  def lower(%AST.Agent{} = ast) do
    state_fields = extract_state_fields(ast.body)
    has_state = state_fields != []
    params = extract_params(ast.params)
    param_names = MapSet.new(params, fn {name, _type} -> name end)

    ir = %IR.Agent{
      name: ast.name,
      module: Module.concat([Vor, Agent, ast.name]),
      behaviour: if(has_state, do: :gen_statem, else: :gen_server),
      params: params,
      state_fields: state_fields,
      protocol: extract_protocol(ast.body),
      handlers: extract_handlers(ast.body, param_names),
      relations: extract_relations(ast.body),
      invariants: extract_invariants(ast.body),
      resilience: nil,
      externs: extract_externs(ast.body)
    }

    {:ok, ir}
  end

  defp extract_params(nil), do: []
  defp extract_params([]), do: []
  defp extract_params(params) do
    Enum.map(params, fn {name, type} -> {to_atom(name), to_atom(type)} end)
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

  defp extract_handlers(body, param_names) do
    body
    |> Enum.filter(&match?(%AST.Handler{}, &1))
    |> Enum.map(&lower_handler(&1, param_names))
  end

  defp lower_handler(%AST.Handler{pattern: pattern, guard: guard, body: body}, param_names) do
    %IR.Handler{
      pattern: lower_pattern(pattern),
      guard: lower_guard(guard),
      actions: Enum.map(body, &lower_action(&1, param_names))
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

  defp lower_action(%AST.Emit{tag: tag, fields: fields}, param_names) do
    %IR.Action{
      type: :emit,
      data: %IR.EmitAction{
        tag: to_atom(tag),
        fields: Enum.map(fields, fn
          {field, {:var, var}} ->
            {to_atom(field), lower_value_ref(var, param_names)}
          {field, {:atom, val}} ->
            {to_atom(field), {:atom, to_atom(val)}}
          {field, {:expr, %AST.ArithExpr{op: op, left: left, right: right}}} ->
            {to_atom(field), {:arith, op, lower_expr_operand(left, param_names), lower_expr_operand(right, param_names)}}
        end)
      }
    }
  end

  defp lower_action(%AST.IfElse{condition: cond_ast, then_body: then_body, else_body: else_body}, param_names) do
    %IR.Action{
      type: :conditional,
      data: %IR.ConditionalAction{
        condition: lower_condition(cond_ast, param_names),
        then_actions: Enum.map(then_body, &lower_action(&1, param_names)),
        else_actions: Enum.map(else_body, &lower_action(&1, param_names))
      }
    }
  end

  defp lower_action(%AST.Transition{field: field, value: value}, _param_names) do
    %IR.Action{
      type: :transition,
      data: %IR.TransitionAction{
        field: to_atom(field),
        value: to_atom(value)
      }
    }
  end

  defp lower_action(%AST.StartTimer{name: name}, _param_names) do
    %IR.Action{
      type: :start_timer,
      data: %IR.TimerAction{op: :start, name: to_atom(name), args: []}
    }
  end

  defp lower_action(%AST.CancelTimer{name: name}, _param_names) do
    %IR.Action{
      type: :cancel_timer,
      data: %IR.TimerAction{op: :cancel, name: to_atom(name), args: []}
    }
  end

  defp lower_action(%AST.RestartTimer{name: name, args: args}, _param_names) do
    %IR.Action{
      type: :restart_timer,
      data: %IR.TimerAction{op: :restart, name: to_atom(name), args: args}
    }
  end

  defp lower_action(%AST.FunctionCall{name: name, args: args}, _param_names) do
    %IR.Action{
      type: :function_call,
      data: %IR.FunctionCallAction{name: to_atom(name), args: args}
    }
  end

  defp lower_action(%AST.ExternCall{module: mod, function: func, args: args, bind: bind}, param_names) do
    %IR.Action{
      type: :extern_call,
      data: %IR.ExternCallAction{
        module: lower_extern_module(mod),
        function: to_atom(func),
        args: Enum.map(args, fn
          {field, {:var, var}} -> {to_atom(field), lower_value_ref(var, param_names)}
          {field, {:atom, val}} -> {to_atom(field), {:atom, to_atom(val)}}
        end),
        bind: if(bind, do: to_atom(bind), else: nil),
        trusted: false
      }
    }
  end

  defp lower_value_ref(var, param_names) do
    var_atom = to_atom(var)
    if MapSet.member?(param_names, var_atom) do
      {:param, var_atom}
    else
      {:bound_var, var_atom}
    end
  end

  defp lower_expr_operand({:var, var}, param_names), do: lower_value_ref(var, param_names)
  defp lower_expr_operand({:integer, n}, _param_names), do: {:integer, n}
  defp lower_expr_operand({:atom, a}, _param_names), do: {:atom, to_atom(a)}

  defp lower_condition(%AST.Comparison{left: left, op: op, right: right}, param_names) do
    %IR.Condition{
      left: lower_expr_operand(left, param_names),
      op: op,
      right: lower_expr_operand(right, param_names)
    }
  end

  defp extract_externs(body) do
    body
    |> Enum.filter(&match?(%AST.ExternBlock{}, &1))
    |> Enum.flat_map(fn %AST.ExternBlock{declarations: decls} ->
      Enum.map(decls, fn %AST.ExternDecl{module: mod, function: func, args: args, return_type: ret} ->
        %IR.ExternDecl{
          module: lower_extern_module(mod),
          function: to_atom(func),
          args: Enum.map(args, fn {n, t} -> {to_atom(n), to_atom(t)} end),
          return_type: ret,
          trusted: false
        }
      end)
    end)
  end

  defp lower_extern_module({:erlang_mod, mod}), do: {:erlang_mod, to_atom(mod)}
  defp lower_extern_module(mod), do: Module.concat([to_atom(mod)])

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
