defmodule Vor.Lowering do
  @moduledoc """
  Transforms Vor AST into the Core IR.
  Resolves agent behaviour, module names, variable bindings.
  """

  alias Vor.{AST, IR}

  def lower(%AST.Agent{} = ast) do
    {state_fields, data_fields} = extract_state_and_data_fields(ast.body)
    has_state = state_fields != []
    params = extract_params(ast.params)
    param_names = MapSet.new(params, fn {name, _type} -> name end)
    data_field_names = MapSet.new(data_fields, fn %IR.DataField{name: name} -> name end)
    # Combine param_names and data_field_names for variable resolution
    known_names = MapSet.union(param_names, data_field_names)

    all_states = case state_fields do
      [%IR.StateField{values: vals} | _] -> vals
      _ -> []
    end

    relations = extract_relations(ast.body)
    relation_map = Map.new(relations, fn r -> {r.name, r} end)

    state_field_name = case state_fields do
      [%IR.StateField{name: name} | _] -> name
      _ -> :phase
    end

    monitors = extract_monitors(ast.body, all_states, known_names)
    {init_handler, regular_handlers} = extract_init_and_handlers(ast.body, known_names, relation_map)
    handlers = regular_handlers
    timeout_handlers = generate_timeout_handlers(monitors, known_names, state_field_name)
    periodic_timers = extract_periodic_timers(ast.body, known_names)

    ir = %IR.Agent{
      name: ast.name,
      module: Module.concat([Vor, Agent, ast.name]),
      behaviour: if(has_state, do: :gen_statem, else: :gen_server),
      params: params,
      state_fields: state_fields,
      data_fields: data_fields,
      protocol: extract_protocol(ast.body),
      handlers: handlers ++ timeout_handlers,
      relations: relations,
      invariants: extract_invariants(ast.body),
      resilience: nil,
      externs: extract_externs(ast.body),
      monitors: monitors,
      periodic_timers: periodic_timers,
      init_handler: init_handler
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

  defp extract_state_and_data_fields(body) do
    decls = Enum.filter(body, &match?(%AST.StateDecl{}, &1))

    # First state decl with a | union of atoms becomes the state field
    # All others become data fields
    {state_fields, data_fields} =
      Enum.reduce(decls, {[], []}, fn %AST.StateDecl{field: field, type_union: types, sensitive: sensitive}, {sf, df} ->
        cond do
          # Already have a state field, or this is a type reference (not enum)
          sf != [] ->
            {sf, [make_data_field(field, types, sensitive) | df]}

          is_enum_type?(types) ->
            state = %IR.StateField{
              name: to_atom(field),
              values: Enum.map(types, &to_atom/1),
              initial: to_atom(List.first(types))
            }
            {[state], df}

          true ->
            {sf, [make_data_field(field, types, sensitive) | df]}
        end
      end)

    {state_fields, Enum.reverse(data_fields)}
  end

  defp is_enum_type?(types) do
    # An enum type has multiple atoms joined by |
    length(types) > 1 and Enum.all?(types, fn
      {:type, _} -> false
      _ -> true
    end)
  end

  defp make_data_field(field, types, sensitive \\ false) do
    {type, default} = case types do
      [{:type, t}] ->
        d = case to_atom(t) do
          :integer -> 0
          :atom -> nil
          :term -> nil
          :map -> :__empty_map__
          :list -> :__empty_list__
          :binary -> :__empty_binary__
          _ -> nil
        end
        {to_atom(t), d}
      _ ->
        {:atom, nil}
    end
    %IR.DataField{name: to_atom(field), type: type, default: default, sensitive: sensitive == true}
  end

  defp extract_protocol(body) do
    case Enum.find(body, &match?(%AST.Protocol{}, &1)) do
      nil ->
        %IR.Protocol{accepts: [], emits: []}

      %AST.Protocol{accepts: accepts, emits: emits, sends: sends} ->
        %IR.Protocol{
          accepts: Enum.map(accepts, &lower_message_spec/1),
          emits: Enum.map(emits, &lower_message_spec/1),
          sends: Enum.map(sends || [], &lower_message_spec/1)
        }
    end
  end

  defp lower_message_spec(%AST.MessageSpec{tag: tag, fields: fields}) do
    %IR.MessageType{
      tag: to_atom(tag),
      fields: Enum.map(fields, fn {name, type} -> {to_atom(name), to_atom(type)} end)
    }
  end

  defp lower_handler(%AST.Handler{pattern: pattern, guard: guard, body: body}, param_names, relation_map) do
    # Collect bound variable names from the handler pattern
    pattern_vars = case pattern do
      %AST.Pattern{bindings: bindings} ->
        Enum.flat_map(bindings, fn
          {_field, {:var, var}} -> [to_atom(var)]
          _ -> []
        end)
        |> MapSet.new()
      _ -> MapSet.new()
    end

    # For solve calls, we need to resolve the relation and embed its data
    actions = body
    |> Enum.map(fn action ->
      case action do
        %AST.Solve{} -> lower_solve_action(action, param_names, relation_map, pattern_vars)
        other -> lower_action(other, param_names)
      end
    end)
    |> Enum.reject(&is_nil/1)

    %IR.Handler{
      pattern: lower_pattern(pattern),
      guard: lower_guard(guard, param_names),
      actions: actions
    }
  end

  defp lower_solve_action(%AST.Solve{relation: rel_name, bindings: bindings, body: body}, param_names, relation_map, pattern_vars) do
    rel_atom = to_atom(rel_name)
    relation = Map.get(relation_map, rel_atom)
    all_known = MapSet.union(param_names, pattern_vars)

    bindings_lowered = Enum.map(bindings, fn
      {field, {:var, var}} -> {to_atom(field), {:var, to_atom(var)}}
      {field, {:integer, n}} -> {to_atom(field), {:integer, n}}
      {field, {:atom, a}} -> {to_atom(field), {:atom, to_atom(a)}}
    end)

    # Determine bound vs unbound fields
    {bound, unbound} = Enum.split_with(bindings_lowered, fn
      {_field, {:var, var}} -> MapSet.member?(all_known, var)
      {_field, {:integer, _}} -> true
      {_field, {:atom, _}} -> true
      _ -> false
    end)

    bound_fields = Enum.map(bound, fn {f, _} -> f end)
    unbound_fields = Enum.map(unbound, fn {f, _} -> f end)

    %IR.Action{
      type: :solve,
      data: %IR.SolveAction{
        relation_name: rel_atom,
        bindings: bindings_lowered,
        bound_fields: bound_fields,
        unbound_fields: unbound_fields,
        body_actions: Enum.map(body, &lower_action(&1, param_names)),
        equation: if(relation, do: relation.equation, else: nil),
        facts: if(relation, do: relation.facts, else: [])
      }
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

  defp lower_guard(nil, _known_names), do: nil

  defp lower_guard(%AST.Guard{field: field, op: op, value: value}, known_names) do
    %IR.GuardExpr{
      field: to_atom(field),
      op: op,
      value: lower_guard_value(value, known_names)
    }
  end

  defp lower_guard(%AST.CompoundGuard{op: op, left: left, right: right}, known_names) do
    %IR.CompoundGuardExpr{
      op: op,
      left: lower_guard(left, known_names),
      right: lower_guard(right, known_names)
    }
  end

  defp lower_guard_value({:atom, v}, _known_names), do: {:atom, to_atom(v)}
  defp lower_guard_value({:var, v}, known_names) do
    var_atom = to_atom(v)
    if MapSet.member?(known_names, var_atom) do
      {:param, var_atom}
    else
      {:var, var_atom}
    end
  end
  defp lower_guard_value({:integer, n}, _known_names), do: {:integer, n}
  defp lower_guard_value({:range, low, high}, _known_names), do: {:range, low, high}
  defp lower_guard_value(other, _known_names), do: other

  defp lower_field_value({:var, var}, param_names), do: lower_value_ref(var, param_names)
  defp lower_field_value({:atom, val}, _param_names), do: {:atom, to_atom(val)}
  defp lower_field_value({:integer, n}, _param_names), do: {:integer, n}
  defp lower_field_value({:expr, %AST.ArithExpr{op: op, left: left, right: right}}, param_names) do
    {:arith, op, lower_expr_operand(left, param_names), lower_expr_operand(right, param_names)}
  end
  defp lower_field_value({:list, elements}, param_names) do
    {:list, Enum.map(elements, fn elem -> lower_field_value(elem, param_names) end)}
  end
  defp lower_field_value({:builtin, %AST.MapOp{op: op, args: args}}, param_names) do
    {:map_op, op, Enum.map(args, fn a -> lower_field_value(a, param_names) end)}
  end
  defp lower_field_value({:builtin, %AST.MinMax{op: op, left: left, right: right}}, param_names) do
    {:minmax, op, lower_field_value(left, param_names), lower_field_value(right, param_names)}
  end

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
          {field, {:integer, n}} ->
            {to_atom(field), {:integer, n}}
          {field, {:list, _} = list_val} ->
            {to_atom(field), lower_field_value(list_val, param_names)}
          {field, {:builtin, _} = bv} ->
            {to_atom(field), lower_field_value(bv, param_names)}
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

  defp lower_action(%AST.Transition{field: field, value: {:expr, %AST.ArithExpr{op: op, left: left, right: right}}}, param_names) do
    %IR.Action{
      type: :transition,
      data: %IR.TransitionAction{
        field: to_atom(field),
        value: {:arith, op, lower_expr_operand(left, param_names), lower_expr_operand(right, param_names)}
      }
    }
  end

  defp lower_action(%AST.Transition{field: field, value: {:var, var}}, param_names) do
    %IR.Action{
      type: :transition,
      data: %IR.TransitionAction{
        field: to_atom(field),
        value: lower_value_ref(var, param_names)
      }
    }
  end

  defp lower_action(%AST.Transition{field: field, value: {:integer, n}}, _param_names) do
    %IR.Action{
      type: :transition,
      data: %IR.TransitionAction{
        field: to_atom(field),
        value: {:integer, n}
      }
    }
  end

  defp lower_action(%AST.Transition{field: field, value: {:builtin, builtin}}, param_names) do
    %IR.Action{
      type: :transition,
      data: %IR.TransitionAction{
        field: to_atom(field),
        value: lower_field_value({:builtin, builtin}, param_names)
      }
    }
  end

  defp lower_action(%AST.Transition{field: field, value: value}, _param_names) when is_atom(value) or is_binary(value) do
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

  defp lower_action(%AST.VarBinding{name: name, expr: %AST.ArithExpr{op: op, left: left, right: right}}, param_names) do
    %IR.Action{
      type: :var_binding,
      data: %IR.VarBindingAction{
        name: to_atom(name),
        expr: {:arith, op, lower_expr_operand(left, param_names), lower_expr_operand(right, param_names)}
      }
    }
  end

  defp lower_action(%AST.VarBinding{name: name, expr: %AST.MapOp{op: op, args: args}}, param_names) do
    %IR.Action{
      type: :var_binding,
      data: %IR.VarBindingAction{
        name: to_atom(name),
        expr: {:map_op, op, Enum.map(args, fn a -> lower_field_value(a, param_names) end)}
      }
    }
  end

  defp lower_action(%AST.VarBinding{name: name, expr: %AST.MinMax{op: op, left: left, right: right}}, param_names) do
    %IR.Action{
      type: :var_binding,
      data: %IR.VarBindingAction{
        name: to_atom(name),
        expr: {:minmax, op, lower_field_value(left, param_names), lower_field_value(right, param_names)}
      }
    }
  end

  defp lower_action(%AST.VarBinding{name: name, expr: {:var, var}}, param_names) do
    %IR.Action{
      type: :var_binding,
      data: %IR.VarBindingAction{
        name: to_atom(name),
        expr: lower_value_ref(var, param_names)
      }
    }
  end

  defp lower_action(%AST.VarBinding{name: name, expr: {:atom, val}}, _param_names) do
    %IR.Action{
      type: :var_binding,
      data: %IR.VarBindingAction{
        name: to_atom(name),
        expr: {:atom, to_atom(val)}
      }
    }
  end

  defp lower_action(%AST.VarBinding{name: name, expr: {:integer, val}}, _param_names) do
    %IR.Action{
      type: :var_binding,
      data: %IR.VarBindingAction{
        name: to_atom(name),
        expr: {:integer, val}
      }
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

  # Solve without relation_map — fallback (shouldn't normally be reached)
  defp lower_action(%AST.Solve{} = solve, param_names) do
    lower_solve_action(solve, param_names, %{}, MapSet.new())
  end

  defp lower_action(%AST.Send{target: target, tag: tag, fields: fields}, param_names) do
    lowered_target = case target do
      {:var, name} -> {:bound_var, to_atom(name)}
      name -> to_atom(name)
    end
    %IR.Action{
      type: :send,
      data: %IR.SendAction{
        target: lowered_target,
        tag: to_atom(tag),
        fields: Enum.map(fields, fn
          {field, {:var, var}} -> {to_atom(field), lower_value_ref(var, param_names)}
          {field, {:atom, val}} -> {to_atom(field), {:atom, to_atom(val)}}
          {field, {:expr, %AST.ArithExpr{op: op, left: left, right: right}}} ->
            {to_atom(field), {:arith, op, lower_expr_operand(left, param_names), lower_expr_operand(right, param_names)}}
          {field, {:integer, n}} -> {to_atom(field), {:integer, n}}
          {field, {:list, _} = lv} -> {to_atom(field), lower_field_value(lv, param_names)}
        end)
      }
    }
  end

  defp lower_action(%AST.Noop{}, _param_names), do: nil

  defp lower_action(%AST.Broadcast{tag: tag, fields: fields}, param_names) do
    %IR.Action{
      type: :broadcast,
      data: %IR.BroadcastAction{
        tag: to_atom(tag),
        fields: Enum.map(fields, fn
          {field, {:var, var}} -> {to_atom(field), lower_value_ref(var, param_names)}
          {field, {:atom, val}} -> {to_atom(field), {:atom, to_atom(val)}}
          {field, {:expr, %AST.ArithExpr{op: op, left: left, right: right}}} ->
            {to_atom(field), {:arith, op, lower_expr_operand(left, param_names), lower_expr_operand(right, param_names)}}
          {field, {:integer, n}} -> {to_atom(field), {:integer, n}}
          {field, {:list, _} = lv} -> {to_atom(field), lower_field_value(lv, param_names)}
        end)
      }
    }
  end

  defp lower_value_ref(var, known_names) do
    var_atom = to_atom(var)
    if MapSet.member?(known_names, var_atom) do
      # Both params and data fields are stored in the same map (State for gen_server, Data for gen_statem)
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

  defp lower_condition(%AST.CompoundComparison{op: op, left: left, right: right}, param_names) do
    %IR.CompoundCondition{
      op: op,
      left: lower_condition(left, param_names),
      right: lower_condition(right, param_names)
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
  defp lower_extern_module({:gleam_mod, mod}), do: {:gleam_mod, to_atom(mod)}
  defp lower_extern_module(mod), do: Module.concat([to_atom(mod)])

  defp extract_relations(body) do
    body
    |> Enum.filter(&match?(%AST.Relation{}, &1))
    |> Enum.map(fn rel ->
      equation = case Map.get(rel, :equation) do
        %AST.RelationEquation{lhs: lhs, rhs: rhs} ->
          {:assign, to_atom(lhs), lower_solver_expr(rhs)}
        _ -> nil
      end

      %IR.Relation{
        name: to_atom(rel.name),
        params: Enum.map(rel.params, fn {n, t} -> {to_atom(n), to_atom(t)} end),
        facts: Enum.map(rel.facts || [], fn %AST.Fact{fields: fields} ->
          Enum.map(fields, fn {k, v} -> {to_atom(k), lower_fact_value(v)} end)
        end),
        equation: equation
      }
    end)
  end

  defp lower_solver_expr({:ref, name}), do: {:ref, to_atom(name)}
  defp lower_solver_expr({op, left, right}) when op in [:add, :sub, :mul, :div] do
    {op, lower_solver_expr(left), lower_solver_expr(right)}
  end
  defp lower_solver_expr(n) when is_number(n), do: n

  defp lower_fact_value({:atom, v}), do: {:atom, to_atom(v)}
  defp lower_fact_value({:integer, v}), do: {:integer, v}
  defp lower_fact_value({:multiply, a, b}), do: {:multiply, lower_fact_value(a), lower_fact_value(b)}
  defp lower_fact_value(other), do: other

  defp extract_monitors(body, all_states, _known_names) do
    liveness_invariants =
      body
      |> Enum.filter(fn
        %AST.Liveness{tier: :monitored, timeout_expr: expr} when not is_nil(expr) -> true
        _ -> false
      end)

    resilience_map = extract_resilience_map(body)

    Enum.flat_map(liveness_invariants, fn %AST.Liveness{name: name, timeout_expr: timeout_expr, body: body_tokens} ->
      {excluded, target} = parse_liveness_states(body_tokens)
      monitored = all_states -- ([target | excluded])
      event_tag = :"liveness_timeout_#{String.replace(name, " ", "_")}"

      resilience_actions = Map.get(resilience_map, name, [])

      [%IR.LivenessMonitor{
        name: name,
        timeout_expr: timeout_expr,
        excluded_states: excluded,
        target_state: target,
        monitored_states: monitored,
        resilience_actions: resilience_actions,
        event_tag: event_tag
      }]
    end)
  end

  defp extract_resilience_map(body) do
    body
    |> Enum.filter(&match?(%AST.Resilience{}, &1))
    |> Enum.flat_map(fn %AST.Resilience{handlers: handlers} ->
      case handlers do
        handlers when is_list(handlers) ->
          Enum.flat_map(handlers, fn
            %AST.ResilienceHandler{invariant_name: name, actions: actions} ->
              [{name, actions}]
            _ -> []
          end)
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp parse_liveness_states(tokens) when is_list(tokens) do
    excluded = tokens
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.flat_map(fn
      [{:identifier, _, _field}, {:operator, _, :!=}, {:atom, _, state}] -> [String.to_atom(state)]
      _ -> []
    end)

    target = tokens
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.find_value(fn
      [{:identifier, _, _field}, {:operator, _, :==}, {:atom, _, state}] -> String.to_atom(state)
      _ -> nil
    end)

    {excluded, target || :terminated}
  end

  defp parse_liveness_states(_), do: {[], :terminated}

  defp generate_timeout_handlers(monitors, known_names, state_field_name) do
    Enum.map(monitors, fn %IR.LivenessMonitor{} = monitor ->
      actions = Enum.map(monitor.resilience_actions, &lower_action(&1, known_names))

      actions = if actions == [] do
        [%IR.Action{type: :transition, data: %IR.TransitionAction{field: state_field_name, value: monitor.target_state}}]
      else
        actions
      end

      excluded = [monitor.target_state | monitor.excluded_states]

      %IR.Handler{
        pattern: %IR.MatchPattern{tag: monitor.event_tag, bindings: []},
        guard: %IR.GuardExpr{field: state_field_name, op: :not_in, value: {:states, excluded}},
        actions: actions
      }
    end)
  end

  defp extract_init_and_handlers(body, known_names, relation_map) do
    {init_handlers, regular} = body
    |> Enum.filter(&match?(%AST.Handler{}, &1))
    |> Enum.split_with(fn h -> match?(%AST.Pattern{tag: "init"}, h.pattern) end)

    init = case init_handlers do
      [h] -> lower_handler(h, known_names, relation_map)
      [_ | _] -> :duplicate_init
      [] -> nil
    end

    handlers = Enum.map(regular, &lower_handler(&1, known_names, relation_map))
    {init, handlers}
  end

  defp extract_periodic_timers(body, known_names) do
    body
    |> Enum.filter(&match?(%AST.Every{}, &1))
    |> Enum.with_index()
    |> Enum.map(fn {%AST.Every{interval: interval, body: timer_body}, idx} ->
      lowered_interval = case interval do
        {:integer, n} -> {:integer, n}
        {:param, name} -> {:param, to_atom(name)}
      end

      actions = timer_body
      |> Enum.map(&lower_action(&1, known_names))
      |> Enum.reject(&is_nil/1)

      %IR.PeriodicTimer{
        tag: :"vor_every_#{idx}",
        interval: lowered_interval,
        actions: actions
      }
    end)
  end

  defp extract_invariants(body) do
    safety =
      body
      |> Enum.filter(&match?(%AST.Safety{}, &1))
      |> Enum.map(fn %AST.Safety{name: name, tier: tier, body: body_tokens} ->
        {:safety, name, tier, body_tokens || []}
      end)

    liveness =
      body
      |> Enum.filter(&match?(%AST.Liveness{}, &1))
      |> Enum.map(fn %AST.Liveness{name: name, tier: tier} -> {:liveness, name, tier} end)

    safety ++ liveness
  end
end
