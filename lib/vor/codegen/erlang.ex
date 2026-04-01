defmodule Vor.Codegen.Erlang do
  @moduledoc """
  Transforms Vor IR into Erlang abstract format suitable for :compile.forms/2.
  """

  alias Vor.IR

  def generate(%IR.Agent{behaviour: :gen_server} = agent) do
    l = 1
    forms = List.flatten([
      {:attribute, l, :file, {~c"#{agent.name}.vor", l}},
      {:attribute, l, :module, agent.module},
      {:attribute, l, :behaviour, :gen_server},
      {:attribute, l, :export, [
        {:start_link, 0}, {:start_link, 1},
        {:init, 1}, {:handle_call, 3}, {:handle_cast, 2}, {:handle_info, 2}
      ]},
      gen_start_link(agent, l),
      gen_init_server(agent, l),
      gen_handle_call(agent, l),
      gen_handle_cast(agent, l),
      gen_handle_info(l)
    ])

    {:ok, forms}
  end

  def generate(%IR.Agent{behaviour: :gen_statem} = agent) do
    l = 1
    forms = List.flatten([
      {:attribute, l, :file, {~c"#{agent.name}.vor", l}},
      {:attribute, l, :module, agent.module},
      {:attribute, l, :behaviour, :gen_statem},
      {:attribute, l, :export, [
        {:start_link, 0}, {:start_link, 1},
        {:callback_mode, 0}, {:init, 1}, {:handle_event, 4}
      ]},
      gen_start_link_statem(agent, l),
      gen_callback_mode(l),
      gen_init_statem(agent, l),
      gen_handle_event(agent, l)
    ])

    {:ok, forms}
  end

  # ---- gen_server codegen ----

  defp gen_start_link(agent, l) do
    [
      {:function, l, :start_link, 0, [
        {:clause, l, [], [],
          [{:call, l, {:atom, l, :start_link}, [{:nil, l}]}]}
      ]},
      {:function, l, :start_link, 1, [
        {:clause, l, [{:var, l, :Args}], [],
          [{:call, l,
            {:remote, l, {:atom, l, :gen_server}, {:atom, l, :start_link}},
            [{:atom, l, agent.module}, {:var, l, :Args}, {:nil, l}]}]}
      ]}
    ]
  end

  defp gen_init_server(agent, l) do
    init_map = gen_params_map(agent.params, l)
    {:function, l, :init, 1, [
      {:clause, l, [{:var, l, :Args}], [],
        [{:tuple, l, [{:atom, l, :ok}, init_map]}]}
    ]}
  end

  defp gen_handle_call(agent, l) do
    handler_clauses =
      agent.handlers
      |> Enum.map(fn handler ->
        pattern_form = pattern_to_erl(handler.pattern, l)
        body = compile_handler_body(handler.actions, l)

        {:clause, l,
          [pattern_form, {:var, l, :_From}, {:var, l, :State}],
          guard_to_erl(handler.guard, l),
          body}
      end)

    catchall = {:clause, l,
      [{:var, l, :_Msg}, {:var, l, :_From}, {:var, l, :State}],
      [],
      [{:tuple, l, [{:atom, l, :reply},
                     {:tuple, l, [{:atom, l, :error}, {:atom, l, :unhandled}]},
                     {:var, l, :State}]}]}

    {:function, l, :handle_call, 3, handler_clauses ++ [catchall]}
  end

  defp gen_handle_cast(_agent, l) do
    {:function, l, :handle_cast, 2, [
      {:clause, l, [{:var, l, :_Msg}, {:var, l, :State}], [],
        [{:tuple, l, [{:atom, l, :noreply}, {:var, l, :State}]}]}
    ]}
  end

  defp gen_handle_info(l) do
    {:function, l, :handle_info, 2, [
      {:clause, l, [{:var, l, :_Msg}, {:var, l, :State}], [],
        [{:tuple, l, [{:atom, l, :noreply}, {:var, l, :State}]}]}
    ]}
  end

  # Split actions into pre-emit actions and the emit action
  # Compile a handler's action list into Erlang body expressions for gen_server
  defp compile_handler_body(actions, l) do
    {pre_actions, terminal} = split_terminal(actions)

    pre_exprs = Enum.flat_map(pre_actions, &action_to_erl(&1, l))

    terminal_expr = case terminal do
      %IR.Action{type: :emit, data: emit} ->
        reply_form = emit_to_erl(emit, l)
        {:tuple, l, [{:atom, l, :reply}, reply_form, {:var, l, :State}]}

      %IR.Action{type: :conditional, data: %IR.ConditionalAction{} = cond_action} ->
        compile_conditional(cond_action, l)

      nil ->
        {:tuple, l, [{:atom, l, :reply}, {:atom, l, :ok}, {:var, l, :State}]}
    end

    pre_exprs ++ [terminal_expr]
  end

  defp split_terminal(actions) do
    terminal_idx = Enum.find_index(actions, fn a -> a.type in [:emit, :conditional] end)
    case terminal_idx do
      nil -> {actions, nil}
      idx -> {Enum.take(actions, idx), Enum.at(actions, idx)}
    end
  end

  defp compile_conditional(%IR.ConditionalAction{condition: cond_ir, then_actions: then_acts, else_actions: else_acts}, l) do
    cond_form = condition_to_erl(cond_ir, l)

    then_body = compile_handler_body(then_acts, l)
    else_body = compile_handler_body(else_acts, l)

    {:case, l, cond_form, [
      {:clause, l, [{:atom, l, true}], [], then_body},
      {:clause, l, [{:atom, l, false}], [], else_body}
    ]}
  end

  defp condition_to_erl(%IR.Condition{left: left, op: op, right: right}, l) do
    erl_op = case op do
      :<= -> :"=<"
      :>= -> :>=
      :== -> :==
      :!= -> :"/="
    end
    {:op, l, erl_op, value_to_erl(left, l), value_to_erl(right, l)}
  end

  defp value_to_erl({:bound_var, var}, l), do: {:var, l, erl_var(var)}
  defp value_to_erl({:param, name}, l) do
    {:call, l, {:remote, l, {:atom, l, :maps}, {:atom, l, :get}},
      [{:atom, l, name}, {:var, l, :State}]}
  end
  defp value_to_erl({:integer, n}, l), do: {:integer, l, n}
  defp value_to_erl({:atom, a}, l), do: {:atom, l, a}

  # ---- gen_statem codegen ----

  defp gen_start_link_statem(agent, l) do
    [
      {:function, l, :start_link, 0, [
        {:clause, l, [], [],
          [{:call, l, {:atom, l, :start_link}, [{:nil, l}]}]}
      ]},
      {:function, l, :start_link, 1, [
        {:clause, l, [{:var, l, :_Opts}], [],
          [{:call, l,
            {:remote, l, {:atom, l, :gen_statem}, {:atom, l, :start_link}},
            [{:atom, l, agent.module}, {:nil, l}, {:nil, l}]}]}
      ]}
    ]
  end

  defp gen_callback_mode(l) do
    {:function, l, :callback_mode, 0, [
      {:clause, l, [], [],
        [{:atom, l, :handle_event_function}]}
    ]}
  end

  defp gen_init_statem(agent, l) do
    initial_state = case agent.state_fields do
      [%IR.StateField{initial: initial} | _] -> initial
      _ -> :idle
    end

    init_map = gen_params_map(agent.params, l)

    {:function, l, :init, 1, [
      {:clause, l, [{:var, l, :Args}], [],
        [{:tuple, l, [
          {:atom, l, :ok},
          {:atom, l, initial_state},
          init_map
        ]}]}
    ]}
  end

  defp gen_handle_event(agent, l) do
    handler_clauses =
      agent.handlers
      |> Enum.map(fn handler ->
        pattern_form = pattern_to_erl(handler.pattern, l)
        actions = handler.actions
        {statem_actions, new_state} = compile_statem_actions(actions, l)

        state_result = case new_state do
          nil -> {:var, l, :State}
          value -> {:atom, l, value}
        end

        body = case statem_actions do
          [] ->
            [{:tuple, l, [{:atom, l, :next_state}, state_result, {:var, l, :Data}, {:nil, l}]}]

          _ ->
            actions_list = list_to_erl(statem_actions, l)
            [{:tuple, l, [{:atom, l, :next_state}, state_result, {:var, l, :Data}, actions_list]}]
        end

        guard_erl = statem_guard_to_erl(handler.guard, l)

        {:clause, l,
          [{:atom, l, :cast}, pattern_form, {:var, l, :State}, {:var, l, :Data}],
          guard_erl,
          body}
      end)

    # Timer fired events: :info handlers
    timer_clauses = gen_timer_info_clauses(agent, l)

    # Catch-all
    catchall = {:clause, l,
      [{:var, l, :_Type}, {:var, l, :_Event}, {:var, l, :_State}, {:var, l, :_Data}],
      [],
      [{:atom, l, :keep_state_and_data}]}

    {:function, l, :handle_event, 4, handler_clauses ++ timer_clauses ++ [catchall]}
  end

  defp compile_statem_actions(actions, _l) do
    {statem_actions, new_state} =
      Enum.reduce(actions, {[], nil}, fn action, {acts, state} ->
        case action do
          %IR.Action{type: :emit, data: %IR.EmitAction{}} ->
            # For gen_statem cast handlers, emits are stored in data for retrieval
            # (no reply possible on a cast). Future: send to registered listeners.
            {acts, state}

          %IR.Action{type: :transition, data: %IR.TransitionAction{value: value}} ->
            {acts, value}

          %IR.Action{type: :start_timer, data: %IR.TimerAction{name: _name}} ->
            # Timer start/cancel managed via erlang:send_after at runtime.
            # For now, these are no-ops — the test simulates timer firing via send/2.
            {acts, state}

          %IR.Action{type: :cancel_timer, data: %IR.TimerAction{name: _name}} ->
            {acts, state}

          %IR.Action{type: :function_call, data: _} ->
            # Opaque function calls — skip for now
            {acts, state}

          _ ->
            {acts, state}
        end
      end)

    {Enum.reverse(statem_actions), new_state}
  end

  defp gen_timer_info_clauses(agent, l) do
    agent.handlers
    |> Enum.filter(fn h -> h.pattern.tag |> Atom.to_string() |> String.ends_with?("_fired") end)
    |> Enum.map(fn handler ->
      actions = handler.actions
      {_statem_actions, new_state} = compile_statem_actions(actions, l)

      state_result = case new_state do
        nil -> {:var, l, :State}
        value -> {:atom, l, value}
      end

      guard_erl = statem_guard_to_erl(handler.guard, l)

      {:clause, l,
        [{:atom, l, :info}, {:atom, l, handler.pattern.tag}, {:var, l, :State}, {:var, l, :Data}],
        guard_erl,
        [{:tuple, l, [{:atom, l, :next_state}, state_result, {:var, l, :Data}]}]}
    end)
  end

  # ---- Shared helpers ----

  defp pattern_to_erl(%IR.MatchPattern{tag: tag, bindings: bindings}, l) do
    map_pairs = Enum.map(bindings, fn
      %IR.Binding{name: {:literal, value}, field: field} ->
        {:map_field_exact, l, {:atom, l, field}, {:atom, l, value}}
      %IR.Binding{name: name, field: field} ->
        {:map_field_exact, l, {:atom, l, field}, {:var, l, erl_var(name)}}
    end)

    {:tuple, l, [{:atom, l, tag}, {:map, l, map_pairs}]}
  end

  defp emit_to_erl(%IR.EmitAction{tag: tag, fields: fields}, l) do
    map_pairs = Enum.map(fields, fn
      {field, {:bound_var, var}} ->
        {:map_field_assoc, l, {:atom, l, field}, {:var, l, erl_var(var)}}
      {field, {:atom, value}} ->
        {:map_field_assoc, l, {:atom, l, field}, {:atom, l, value}}
      {field, {:param, name}} ->
        {:map_field_assoc, l, {:atom, l, field}, value_to_erl({:param, name}, l)}
      {field, {:arith, op, left, right}} ->
        erl_op = arith_op(op)
        {:map_field_assoc, l, {:atom, l, field},
          {:op, l, erl_op, value_to_erl(left, l), value_to_erl(right, l)}}
    end)

    {:tuple, l, [{:atom, l, tag}, {:map, l, map_pairs}]}
  end

  defp guard_to_erl(nil, _l), do: []

  defp guard_to_erl(%IR.GuardExpr{field: field, op: :==, value: {:atom, val}}, l) do
    [[{:op, l, :==, {:var, l, erl_var(field)}, {:atom, l, val}}]]
  end

  defp guard_to_erl(%IR.CompoundGuardExpr{op: :and, left: left, right: right}, l) do
    left_guards = guard_to_erl(left, l)
    right_guards = guard_to_erl(right, l)
    case {left_guards, right_guards} do
      {[[lg]], [[rg]]} -> [[lg, rg]]
      _ -> left_guards ++ right_guards
    end
  end

  defp guard_to_erl(_, _l), do: []

  # For gen_statem, guards check the State variable
  defp statem_guard_to_erl(nil, _l), do: []

  defp statem_guard_to_erl(%IR.GuardExpr{field: _field, op: :==, value: {:atom, val}}, l) do
    [[{:op, l, :==, {:var, l, :State}, {:atom, l, val}}]]
  end

  defp statem_guard_to_erl(%IR.CompoundGuardExpr{op: :and, left: left, right: right}, l) do
    left_guards = statem_guard_to_erl(left, l)
    right_guards = statem_guard_to_erl(right, l)
    # Flatten into a single guard conjunction
    case {left_guards, right_guards} do
      {[lg], [rg]} -> [lg ++ rg]
      _ -> left_guards ++ right_guards
    end
  end

  defp statem_guard_to_erl(%IR.GuardExpr{field: field, op: :in, value: {:range, low, high}}, l) do
    var = {:var, l, erl_var(field)}
    [[
      {:op, l, :>=, var, {:integer, l, low}},
      {:op, l, :"=<", var, {:integer, l, high}}
    ]]
  end

  defp statem_guard_to_erl(_, _l), do: []

  # Build init state map from params: #{param1 => proplists:get_value(param1, Args), ...}
  defp gen_params_map(nil, l), do: {:map, l, []}
  defp gen_params_map([], l), do: {:map, l, []}
  defp gen_params_map(params, l) do
    map_pairs = Enum.map(params, fn {name, _type} ->
      {:map_field_assoc, l, {:atom, l, name},
        {:call, l, {:remote, l, {:atom, l, :proplists}, {:atom, l, :get_value}},
          [{:atom, l, name}, {:var, l, :Args}]}}
    end)
    {:map, l, map_pairs}
  end

  defp arith_op(:minus), do: :-
  defp arith_op(:plus), do: :+
  defp arith_op(:star), do: :*
  defp arith_op(:slash), do: :div

  defp erl_var(name) when is_atom(name) do
    name
    |> Atom.to_string()
    |> String.capitalize()
    |> String.to_atom()
  end

  # --- Action codegen ---

  # Generate Erlang expressions for pre-actions (extern calls, etc.)
  defp action_to_erl(%IR.Action{type: :extern_call, data: %IR.ExternCallAction{} = ext}, l) do
    # Resolve the module atom for the call
    mod_atom = case ext.module do
      {:erlang_mod, m} -> m
      m -> m  # Elixir modules already have the Elixir. prefix from Module.concat
    end

    # Build argument list — extract values from keyword args
    arg_forms = Enum.map(ext.args, fn
      {_field, ref} -> value_to_erl(ref, l)
    end)

    # The actual function call
    call_form = {:call, l,
      {:remote, l, {:atom, l, mod_atom}, {:atom, l, ext.function}},
      arg_forms}

    # Wrap in try/catch
    try_form = {:try, l,
      [call_form],  # body
      [],           # case clauses (none)
      [             # catch clauses
        {:clause, l,
          [{:tuple, l, [{:var, l, :Class}, {:var, l, :Reason}, {:var, l, :Stacktrace}]}],
          [],
          [{:tuple, l, [
            {:atom, l, :vor_extern_error},
            {:var, l, :Class},
            {:var, l, :Reason},
            {:var, l, :Stacktrace}
          ]}]}
      ],
      []}           # after (none)

    case ext.bind do
      nil ->
        [try_form]
      bind_var ->
        # Result = try ... catch ... end
        [{:match, l, {:var, l, erl_var(bind_var)}, try_form}]
    end
  end

  defp action_to_erl(_action, _l), do: []

  defp list_to_erl([], l), do: {:nil, l}
  defp list_to_erl([h | t], l), do: {:cons, l, h, list_to_erl(t, l)}
end
