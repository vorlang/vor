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
    param_pairs = gen_params_map_pairs(agent.params, l)
    data_field_pairs = gen_data_field_pairs(agent.data_fields || [], l)
    init_map = {:map, l, param_pairs ++ data_field_pairs}

    # Build init body that extracts system metadata if present
    body = gen_init_with_metadata(init_map, l, fn data_var ->
      {:tuple, l, [{:atom, l, :ok}, {:var, l, data_var}]}
    end)

    {:function, l, :init, 1, [
      {:clause, l, [{:var, l, :Args}], [], body}
    ]}
  end

  defp gen_handle_call(agent, l) do
    handler_clauses =
      agent.handlers
      |> Enum.map(fn handler ->
        pattern_form = pattern_to_erl(handler.pattern, l)
        body = compile_handler_body(handler.actions, l, :State)

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

    # Generate catch-all clauses for guarded message tags
    guarded_catchalls = gen_guarded_catchall_call_clauses(agent, l)

    {:function, l, :handle_call, 3, handler_clauses ++ guarded_catchalls ++ [catchall]}
  end

  defp gen_handle_cast(agent, l) do
    handler_clauses =
      agent.handlers
      |> Enum.map(fn handler ->
        pattern_form = pattern_to_erl(handler.pattern, l)
        {pre_actions, terminal} = split_terminal(handler.actions)

        # Separate transitions from other pre-actions
        {transitions, other_pre} = Enum.split_with(pre_actions, fn a -> a.type == :transition end)
        pre_exprs = Enum.flat_map(other_pre, &action_to_erl(&1, l, :State))

        # Generate state update from transitions
        {state_update_exprs, state_var} = gen_server_state_updates(transitions, l)

        # For cast, ignore emit value — just update state
        terminal_exprs = case terminal do
          %IR.Action{type: :conditional, data: %IR.ConditionalAction{} = cond_action} ->
            # Execute conditional for side effects (state updates inside branches)
            [compile_conditional_genserver(cond_action, l, (if transitions != [], do: :NewState, else: :State), state_var)]
          _ ->
            []
        end

        result = {:tuple, l, [{:atom, l, :noreply}, {:var, l, state_var}]}

        {:clause, l,
          [pattern_form, {:var, l, :State}],
          guard_to_erl(handler.guard, l),
          pre_exprs ++ state_update_exprs ++ terminal_exprs ++ [result]}
      end)

    catchall = {:clause, l,
      [{:var, l, :_Msg}, {:var, l, :State}],
      [],
      [{:tuple, l, [{:atom, l, :noreply}, {:var, l, :State}]}]}

    {:function, l, :handle_cast, 2, handler_clauses ++ [catchall]}
  end

  defp gen_handle_info(l) do
    {:function, l, :handle_info, 2, [
      {:clause, l, [{:var, l, :_Msg}, {:var, l, :State}], [],
        [{:tuple, l, [{:atom, l, :noreply}, {:var, l, :State}]}]}
    ]}
  end

  # Compile a handler's action list into Erlang body expressions for gen_server
  defp compile_handler_body(actions, l, map_var) do
    {pre_actions, terminal} = split_terminal(actions)

    # Separate transitions from other pre-actions
    {transitions, other_pre} = Enum.split_with(pre_actions, fn a -> a.type == :transition end)

    pre_exprs = Enum.flat_map(other_pre, &action_to_erl(&1, l, map_var))

    # Generate state update from transitions
    {state_update_exprs, state_var} = gen_server_state_updates(transitions, l)

    # After state updates, emit should reference the updated state variable
    emit_map_var = if transitions != [], do: :NewState, else: map_var

    terminal_expr = case terminal do
      %IR.Action{type: :emit, data: emit} ->
        reply_form = emit_to_erl(emit, l, emit_map_var)
        {:tuple, l, [{:atom, l, :reply}, reply_form, {:var, l, state_var}]}

      %IR.Action{type: :conditional, data: %IR.ConditionalAction{} = cond_action} ->
        compile_conditional_genserver(cond_action, l, emit_map_var, state_var)

      %IR.Action{type: :solve, data: %IR.SolveAction{} = solve} ->
        compile_solve_genserver(solve, l, emit_map_var, state_var)

      nil ->
        {:tuple, l, [{:atom, l, :reply}, {:atom, l, :ok}, {:var, l, state_var}]}
    end

    pre_exprs ++ state_update_exprs ++ [terminal_expr]
  end

  # Generate state map updates for gen_server transitions
  defp gen_server_state_updates([], _l), do: {[], :State}
  defp gen_server_state_updates(transitions, l) do
    map_pairs = Enum.map(transitions, fn %IR.Action{type: :transition, data: %IR.TransitionAction{field: field, value: value}} ->
      {:map_field_exact, l, {:atom, l, field}, transition_value_to_erl(value, l, :State)}
    end)
    update_expr = {:match, l, {:var, l, :NewState}, {:map, l, {:var, l, :State}, map_pairs}}
    {[update_expr], :NewState}
  end

  defp transition_value_to_erl(value, l, _map_var) when is_atom(value), do: {:atom, l, value}
  defp transition_value_to_erl({:integer, n}, l, _map_var), do: {:integer, l, n}
  defp transition_value_to_erl({:atom, a}, l, _map_var), do: {:atom, l, a}
  defp transition_value_to_erl({:bound_var, var}, l, _map_var), do: {:var, l, erl_var(var)}
  defp transition_value_to_erl({:param, name}, l, map_var), do: value_to_erl({:param, name}, l, map_var)
  defp transition_value_to_erl({:arith, op, left, right}, l, map_var) do
    {:op, l, arith_op(op), value_to_erl(left, l, map_var), value_to_erl(right, l, map_var)}
  end

  defp split_terminal(actions) do
    terminal_idx = Enum.find_index(actions, fn a -> a.type in [:emit, :conditional, :solve] end)
    case terminal_idx do
      nil -> {actions, nil}
      idx -> {Enum.take(actions, idx), Enum.at(actions, idx)}
    end
  end

  defp compile_conditional_genserver(%IR.ConditionalAction{condition: cond_ir, then_actions: then_acts, else_actions: else_acts}, l, map_var, _state_var) do
    cond_form = condition_to_erl(cond_ir, l, map_var)

    then_body = compile_handler_body(then_acts, l, map_var)
    else_body = compile_handler_body(else_acts, l, map_var)

    {:case, l, cond_form, [
      {:clause, l, [{:atom, l, true}], [], then_body},
      {:clause, l, [{:atom, l, false}], [], else_body}
    ]}
  end

  defp condition_to_erl(%IR.Condition{left: left, op: op, right: right}, l, map_var) do
    erl_op = comparison_op(op)
    {:op, l, erl_op, value_to_erl(left, l, map_var), value_to_erl(right, l, map_var)}
  end

  defp condition_to_erl(%IR.CompoundCondition{op: :and, left: left, right: right}, l, map_var) do
    left_form = condition_to_erl(left, l, map_var)
    right_form = condition_to_erl(right, l, map_var)
    {:op, l, :andalso, left_form, right_form}
  end

  defp condition_to_erl(%IR.CompoundCondition{op: :or, left: left, right: right}, l, map_var) do
    left_form = condition_to_erl(left, l, map_var)
    right_form = condition_to_erl(right, l, map_var)
    {:op, l, :orelse, left_form, right_form}
  end

  defp comparison_op(:<=), do: :"=<"
  defp comparison_op(:>=), do: :>=
  defp comparison_op(:==), do: :==
  defp comparison_op(:!=), do: :"/="
  defp comparison_op(:>), do: :>
  defp comparison_op(:<), do: :<

  # value_to_erl with map_var parameter for gen_server vs gen_statem
  defp value_to_erl({:bound_var, var}, l, _map_var), do: {:var, l, erl_var(var)}
  defp value_to_erl({:param, name}, l, map_var) do
    {:call, l, {:remote, l, {:atom, l, :maps}, {:atom, l, :get}},
      [{:atom, l, name}, {:var, l, map_var}]}
  end
  defp value_to_erl({:integer, n}, l, _map_var), do: {:integer, l, n}
  defp value_to_erl({:atom, a}, l, _map_var), do: {:atom, l, a}
  defp value_to_erl({:arith, op, left, right}, l, map_var) do
    {:op, l, arith_op(op), value_to_erl(left, l, map_var), value_to_erl(right, l, map_var)}
  end

  # Generate init body that extracts system metadata (__vor_registry__, __vor_name__) if present.
  # This makes standalone agents (no system) work unchanged, while system agents get registry info.
  defp gen_init_with_metadata(init_map, l, result_fn) do
    # Data0 = #{params..., fields...}
    data0_bind = {:match, l, {:var, l, :Data0}, init_map}

    # case proplists:get_value('__vor_registry__', Args) of
    #   undefined -> Data0;
    #   Registry ->
    #     Name = proplists:get_value('__vor_name__', Args),
    #     Data0#{'__vor_registry__' => Registry, '__vor_name__' => Name}
    # end
    registry_lookup = {:call, l,
      {:remote, l, {:atom, l, :proplists}, {:atom, l, :get_value}},
      [{:atom, l, :__vor_registry__}, {:var, l, :Args}]}

    name_lookup = {:call, l,
      {:remote, l, {:atom, l, :proplists}, {:atom, l, :get_value}},
      [{:atom, l, :__vor_name__}, {:var, l, :Args}]}

    data_with_meta = {:map, l, {:var, l, :Data0}, [
      {:map_field_assoc, l, {:atom, l, :__vor_registry__}, {:var, l, :VorRegistry}},
      {:map_field_assoc, l, {:atom, l, :__vor_name__}, {:var, l, :VorName}}
    ]}

    name_bind = {:match, l, {:var, l, :VorName}, name_lookup}

    case_expr = {:case, l, registry_lookup, [
      {:clause, l, [{:atom, l, :undefined}], [],
        [{:var, l, :Data0}]},
      {:clause, l, [{:var, l, :VorRegistry}], [],
        [name_bind, data_with_meta]}
    ]}

    data_bind = {:match, l, {:var, l, :Data}, case_expr}

    [data0_bind, data_bind, result_fn.(:Data)]
  end

  # Generate catch-all handle_call clauses for guarded message tags in gen_server
  defp gen_guarded_catchall_call_clauses(agent, l) do
    guarded_tags =
      agent.handlers
      |> Enum.filter(fn h -> h.guard != nil end)
      |> Enum.map(fn h -> h.pattern.tag end)
      |> Enum.uniq()

    Enum.map(guarded_tags, fn tag ->
      pattern = {:tuple, l, [{:atom, l, tag}, {:var, l, :_Fields}]}
      {:clause, l,
        [pattern, {:var, l, :_From}, {:var, l, :State}],
        [],
        [{:tuple, l, [{:atom, l, :reply},
          {:tuple, l, [{:atom, l, :error}, {:atom, l, :no_matching_handler}]},
          {:var, l, :State}]}]}
    end)
  end

  # ---- gen_statem codegen ----

  defp gen_start_link_statem(agent, l) do
    [
      {:function, l, :start_link, 0, [
        {:clause, l, [], [],
          [{:call, l, {:atom, l, :start_link}, [{:nil, l}]}]}
      ]},
      {:function, l, :start_link, 1, [
        {:clause, l, [{:var, l, :Args}], [],
          [{:call, l,
            {:remote, l, {:atom, l, :gen_statem}, {:atom, l, :start_link}},
            [{:atom, l, agent.module}, {:var, l, :Args}, {:nil, l}]}]}
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

    # Build init data map: params from Args + data field defaults
    param_pairs = gen_params_map_pairs(agent.params, l)
    data_field_pairs = gen_data_field_pairs(agent.data_fields || [], l)
    init_map = {:map, l, param_pairs ++ data_field_pairs}

    # Build init body that extracts system metadata if present
    body = gen_init_with_metadata(init_map, l, fn data_var ->
      {:tuple, l, [
        {:atom, l, :ok},
        {:atom, l, initial_state},
        {:var, l, data_var}
      ]}
    end)

    {:function, l, :init, 1, [
      {:clause, l, [{:var, l, :Args}], [], body}
    ]}
  end

  defp gen_handle_event(agent, l) do
    monitors = agent.monitors || []

    state_field_name = case agent.state_fields do
      [%IR.StateField{name: name} | _] -> name
      _ -> :phase
    end

    data_field_names = MapSet.new((agent.data_fields || []), fn %IR.DataField{name: name} -> name end)

    # Generate cast clauses and corresponding call clauses
    {cast_clauses, call_clauses} =
      agent.handlers
      |> Enum.reject(fn h -> is_timeout_handler?(h, monitors) end)
      |> Enum.map(fn handler ->
        pattern_form = pattern_to_erl(handler.pattern, l)
        guard_erl = statem_guard_to_erl(handler.guard, l)

        # Build the handler body for gen_statem
        {body_exprs, new_state, data_updates, emit_form} =
          compile_statem_body(handler.actions, l, state_field_name, data_field_names)

        # Check if there are emits nested in conditionals
        has_conditional_emits = emit_form == nil and has_nested_emits?(handler.actions)

        # Build the result tuple
        state_result = case new_state do
          nil -> {:var, l, :State}
          value when is_atom(value) -> {:atom, l, value}
        end

        # Build the data variable - apply updates if any
        data_result = case data_updates do
          [] -> {:var, l, :Data}
          updates ->
            map_pairs = Enum.map(updates, fn {field, val_form} ->
              {:map_field_exact, l, {:atom, l, field}, val_form}
            end)
            {:map, l, {:var, l, :Data}, map_pairs}
        end

        # Inject state timeout actions for liveness monitoring
        timeout_acts = state_timeout_actions(new_state, monitors, l)
        actions_list = list_to_erl(timeout_acts, l)

        # Cast clause - no reply needed
        cast_body = body_exprs ++ [
          {:tuple, l, [{:atom, l, :next_state}, state_result, data_result, actions_list]}
        ]

        cast_clause = {:clause, l,
          [{:atom, l, :cast}, pattern_form, {:var, l, :State}, {:var, l, :Data}],
          guard_erl,
          cast_body}

        # Call clause - reply with emit value or :ok
        # If emits are inside conditionals, bind the case expr result to VorReply
        {call_body_exprs, reply_value} = cond do
          emit_form != nil ->
            {body_exprs, emit_form}

          has_conditional_emits ->
            # The last body_expr is a case that returns the emit value
            # Bind it to VorReply
            {pre, [last]} = Enum.split(body_exprs, -1)
            binding = {:match, l, {:var, l, :VorReply}, last}
            {pre ++ [binding], {:var, l, :VorReply}}

          true ->
            {body_exprs, {:atom, l, :ok}}
        end

        reply_action = {:tuple, l, [{:atom, l, :reply}, {:var, l, :From}, reply_value]}
        call_actions = list_to_erl([reply_action | timeout_acts], l)

        call_body = call_body_exprs ++ [
          {:tuple, l, [{:atom, l, :next_state}, state_result, data_result, call_actions]}
        ]

        call_clause = {:clause, l,
          [{:tuple, l, [{:atom, l, :call}, {:var, l, :From}]},
           pattern_form, {:var, l, :State}, {:var, l, :Data}],
          guard_erl,
          call_body}

        {cast_clause, call_clause}
      end)
      |> Enum.unzip()

    # Timer fired events: :info handlers
    timer_clauses = gen_timer_info_clauses(agent, l)

    # State timeout handlers (liveness monitoring)
    timeout_clauses = gen_state_timeout_clauses(agent, monitors, l)

    # Catch-all
    catchall = {:clause, l,
      [{:var, l, :_Type}, {:var, l, :_Event}, {:var, l, :_State}, {:var, l, :_Data}],
      [],
      [{:atom, l, :keep_state_and_data}]}

    # Generate catch-all handlers for guarded message tags
    # These prevent crashes when no guard matches — return error for calls, ignore for casts
    guarded_catchalls = gen_guarded_catchall_clauses(agent, l)

    {:function, l, :handle_event, 4, cast_clauses ++ call_clauses ++ guarded_catchalls ++ timer_clauses ++ timeout_clauses ++ [catchall]}
  end

  defp has_nested_emits?(actions) do
    Enum.any?(actions, fn
      %IR.Action{type: :emit} -> true
      %IR.Action{type: :conditional, data: %IR.ConditionalAction{then_actions: ta, else_actions: ea}} ->
        has_nested_emits?(ta) or has_nested_emits?(ea)
      _ -> false
    end)
  end

  defp is_timeout_handler?(handler, monitors) do
    Enum.any?(monitors, fn m -> m.event_tag == handler.pattern.tag end)
  end

  defp state_timeout_actions(nil, _monitors, _l), do: []
  defp state_timeout_actions(new_state, monitors, l) do
    Enum.flat_map(monitors, fn monitor ->
      if new_state in monitor.monitored_states do
        duration = case monitor.timeout_expr do
          {:integer, ms} -> {:integer, l, ms}
          {:param, name} ->
            {:call, l, {:remote, l, {:atom, l, :maps}, {:atom, l, :get}},
              [{:atom, l, name}, {:var, l, :Data}]}
        end
        [{:tuple, l, [{:atom, l, :state_timeout}, duration, {:atom, l, monitor.event_tag}]}]
      else
        []
      end
    end)
  end

  defp gen_state_timeout_clauses(agent, monitors, l) do
    timeout_handlers = agent.handlers
    |> Enum.filter(fn h -> is_timeout_handler?(h, monitors) end)

    Enum.map(timeout_handlers, fn handler ->
      monitor = Enum.find(monitors, fn m -> m.event_tag == handler.pattern.tag end)

      # Find the target state from the handler's actions
      target = Enum.find_value(handler.actions, fn
        %IR.Action{type: :transition, data: %IR.TransitionAction{value: v}} when is_atom(v) -> v
        _ -> nil
      end) || monitor.target_state

      excluded = [monitor.target_state | monitor.excluded_states]
      guard = excluded
      |> Enum.map(fn s -> {:op, l, :"/=", {:var, l, :State}, {:atom, l, s}} end)

      {:clause, l,
        [{:atom, l, :state_timeout}, {:atom, l, handler.pattern.tag}, {:var, l, :State}, {:var, l, :Data}],
        [guard],
        [{:tuple, l, [{:atom, l, :next_state}, {:atom, l, target}, {:var, l, :Data}]}]}
    end)
  end

  # Generate catch-all clauses for message tags that have guarded handlers.
  # When no guard matches: calls get {:error, :no_matching_handler}, casts are silently ignored.
  defp gen_guarded_catchall_clauses(agent, l) do
    monitors = agent.monitors || []

    # Find message tags that have at least one guarded handler
    guarded_tags =
      agent.handlers
      |> Enum.reject(fn h -> is_timeout_handler?(h, monitors) end)
      |> Enum.filter(fn h -> h.guard != nil end)
      |> Enum.map(fn h -> h.pattern.tag end)
      |> Enum.uniq()

    # For each guarded tag, generate a cast catch-all and a call catch-all
    Enum.flat_map(guarded_tags, fn tag ->
      # Build a pattern that matches the tag with any fields: {tag, #{}}
      pattern = {:tuple, l, [{:atom, l, tag}, {:var, l, :_Fields}]}

      # Cast catch-all: silently ignore
      cast_clause = {:clause, l,
        [{:atom, l, :cast}, pattern, {:var, l, :_State}, {:var, l, :_Data}],
        [],
        [{:atom, l, :keep_state_and_data}]}

      # Call catch-all: reply with error
      call_clause = {:clause, l,
        [{:tuple, l, [{:atom, l, :call}, {:var, l, :From}]},
         pattern, {:var, l, :_State}, {:var, l, :_Data}],
        [],
        [{:tuple, l, [
          {:atom, l, :keep_state_and_data},
          list_to_erl([{:tuple, l, [{:atom, l, :reply}, {:var, l, :From},
            {:tuple, l, [{:atom, l, :error}, {:atom, l, :no_matching_handler}]}]}], l)
        ]}]}

      [cast_clause, call_clause]
    end)
  end

  # Compile gen_statem handler body - returns {body_exprs, new_state_atom | nil, data_updates, emit_form | nil}
  defp compile_statem_body(actions, l, state_field_name, data_field_names) do
    {body_exprs, new_state, data_updates, emit_form} =
      Enum.reduce(actions, {[], nil, [], nil}, fn action, {exprs, state, updates, emit} ->
        case action do
          %IR.Action{type: :emit, data: %IR.EmitAction{} = emit_data} ->
            form = emit_to_erl(emit_data, l, :Data)
            {exprs, state, updates, form}

          %IR.Action{type: :transition, data: %IR.TransitionAction{field: field, value: value}} ->
            if field == state_field_name and is_atom(value) do
              # State transition (the gen_statem state atom)
              {exprs, value, updates, emit}
            else
              # Data field update
              val_form = transition_value_to_erl(value, l)
              {exprs, state, updates ++ [{field, val_form}], emit}
            end

          %IR.Action{type: :var_binding, data: %IR.VarBindingAction{name: name, expr: expr}} ->
            binding_form = {:match, l, {:var, l, erl_var(name)}, expr_to_erl(expr, l, :Data)}
            {exprs ++ [binding_form], state, updates, emit}

          %IR.Action{type: :conditional, data: %IR.ConditionalAction{} = cond_action} ->
            cond_form = compile_statem_conditional(cond_action, l, state_field_name, data_field_names)
            {exprs ++ [cond_form], state, updates, emit}

          %IR.Action{type: :send, data: %IR.SendAction{}} = action ->
            send_exprs = action_to_erl(action, l, :Data)
            {exprs ++ send_exprs, state, updates, emit}

          %IR.Action{type: :extern_call, data: %IR.ExternCallAction{}} = action ->
            ext_exprs = action_to_erl(action, l, :Data)
            {exprs ++ ext_exprs, state, updates, emit}

          %IR.Action{type: :start_timer, data: %IR.TimerAction{}} ->
            {exprs, state, updates, emit}

          %IR.Action{type: :cancel_timer, data: %IR.TimerAction{}} ->
            {exprs, state, updates, emit}

          %IR.Action{type: :function_call, data: _} ->
            {exprs, state, updates, emit}

          _ ->
            {exprs, state, updates, emit}
        end
      end)

    {body_exprs, new_state, data_updates, emit_form}
  end

  defp transition_value_to_erl(value, l) when is_atom(value), do: {:atom, l, value}
  defp transition_value_to_erl({:integer, n}, l), do: {:integer, l, n}
  defp transition_value_to_erl({:atom, a}, l), do: {:atom, l, a}
  defp transition_value_to_erl({:bound_var, var}, l), do: {:var, l, erl_var(var)}
  defp transition_value_to_erl({:param, name}, l) do
    {:call, l, {:remote, l, {:atom, l, :maps}, {:atom, l, :get}},
      [{:atom, l, name}, {:var, l, :Data}]}
  end
  defp transition_value_to_erl({:arith, op, left, right}, l) do
    erl_op = arith_op(op)
    {:op, l, erl_op, value_to_erl(left, l, :Data), value_to_erl(right, l, :Data)}
  end

  defp expr_to_erl({:arith, op, left, right}, l, map_var) do
    erl_op = arith_op(op)
    {:op, l, erl_op, value_to_erl(left, l, map_var), value_to_erl(right, l, map_var)}
  end
  defp expr_to_erl({:bound_var, var}, l, _map_var), do: {:var, l, erl_var(var)}
  defp expr_to_erl({:param, name}, l, map_var), do: value_to_erl({:param, name}, l, map_var)
  defp expr_to_erl({:integer, n}, l, _map_var), do: {:integer, l, n}
  defp expr_to_erl({:atom, a}, l, _map_var), do: {:atom, l, a}

  defp compile_statem_conditional(%IR.ConditionalAction{condition: cond_ir, then_actions: then_acts, else_actions: else_acts}, l, state_field_name, data_field_names) do
    cond_form = condition_to_erl(cond_ir, l, :Data)

    # For conditionals inside gen_statem, we compile each branch and wrap in case
    then_body = compile_statem_conditional_branch(then_acts, l, state_field_name, data_field_names)
    else_body = compile_statem_conditional_branch(else_acts, l, state_field_name, data_field_names)

    {:case, l, cond_form, [
      {:clause, l, [{:atom, l, true}], [], then_body},
      {:clause, l, [{:atom, l, false}], [], else_body}
    ]}
  end

  defp compile_statem_conditional_branch(actions, l, state_field_name, data_field_names) do
    {body_exprs, _new_state, _data_updates, emit_form} =
      compile_statem_body(actions, l, state_field_name, data_field_names)

    cond do
      emit_form != nil ->
        # Direct emit - use it as the result
        body_exprs ++ [emit_form]

      body_exprs != [] and has_nested_emits?(actions) ->
        # Emit is nested in a conditional in body_exprs
        # The last body_expr (case) already evaluates to the emit value
        body_exprs

      true ->
        body_exprs ++ [{:atom, l, :ok}]
    end
  end

  defp gen_timer_info_clauses(agent, l) do
    state_field_name = case agent.state_fields do
      [%IR.StateField{name: name} | _] -> name
      _ -> :phase
    end

    data_field_names = MapSet.new((agent.data_fields || []), fn %IR.DataField{name: name} -> name end)

    agent.handlers
    |> Enum.filter(fn h -> h.pattern.tag |> Atom.to_string() |> String.ends_with?("_fired") end)
    |> Enum.map(fn handler ->
      actions = handler.actions
      {_body_exprs, new_state, _data_updates, _emit_form} =
        compile_statem_body(actions, l, state_field_name, data_field_names)

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

  defp emit_to_erl(%IR.EmitAction{tag: tag, fields: fields}, l, map_var) do
    map_pairs = Enum.map(fields, fn
      {field, {:bound_var, var}} ->
        {:map_field_assoc, l, {:atom, l, field}, {:var, l, erl_var(var)}}
      {field, {:atom, value}} ->
        {:map_field_assoc, l, {:atom, l, field}, {:atom, l, value}}
      {field, {:param, name}} ->
        {:map_field_assoc, l, {:atom, l, field}, value_to_erl({:param, name}, l, map_var)}
      {field, {:integer, n}} ->
        {:map_field_assoc, l, {:atom, l, field}, {:integer, l, n}}
      {field, {:arith, op, left, right}} ->
        erl_op = arith_op(op)
        {:map_field_assoc, l, {:atom, l, field},
          {:op, l, erl_op, value_to_erl(left, l, map_var), value_to_erl(right, l, map_var)}}
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

  # Comparison guards on variables (>, <, >=, <=, ==)
  defp statem_guard_to_erl(%IR.GuardExpr{field: field, op: op, value: value}, l)
       when op in [:>, :<, :>=, :<=, :==] do
    erl_op = comparison_op(op)
    left = {:var, l, erl_var(field)}
    right = case value do
      {:var, v} -> {:var, l, erl_var(v)}
      {:integer, n} -> {:integer, l, n}
      {:atom, a} -> {:atom, l, a}
      {:param, name} ->
        {:call, l, {:remote, l, {:atom, l, :maps}, {:atom, l, :get}},
          [{:atom, l, name}, {:var, l, :Data}]}
    end
    [[{:op, l, erl_op, left, right}]]
  end

  defp statem_guard_to_erl(_, _l), do: []

  # Build init state map from params: #{param1 => proplists:get_value(param1, Args), ...}
  defp gen_params_map_pairs(nil, _l), do: []
  defp gen_params_map_pairs([], _l), do: []
  defp gen_params_map_pairs(params, l) do
    Enum.map(params, fn {name, _type} ->
      {:map_field_assoc, l, {:atom, l, name},
        {:call, l, {:remote, l, {:atom, l, :proplists}, {:atom, l, :get_value}},
          [{:atom, l, name}, {:var, l, :Args}]}}
    end)
  end

  defp gen_data_field_pairs([], _l), do: []
  defp gen_data_field_pairs(data_fields, l) do
    Enum.map(data_fields, fn %IR.DataField{name: name, type: _type, default: default} ->
      default_form = case default do
        :__empty_map__ -> {:map, l, []}
        :__empty_list__ -> {:nil, l}
        :__empty_binary__ -> {:bin, l, []}
        nil -> {:atom, l, nil}
        0 -> {:integer, l, 0}
        n when is_integer(n) -> {:integer, l, n}
        a when is_atom(a) -> {:atom, l, a}
      end
      {:map_field_assoc, l, {:atom, l, name}, default_form}
    end)
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

  # Generate Erlang expressions for pre-actions (extern calls, var bindings, etc.)
  # --- Solve codegen ---

  defp compile_solve_genserver(%IR.SolveAction{} = solve, l, map_var, state_var) do
    if solve.equation do
      compile_equation_solve(solve, l, map_var, state_var)
    else
      compile_fact_solve(solve, l, map_var, state_var)
    end
  end

  defp compile_fact_solve(%IR.SolveAction{} = solve, l, map_var, state_var) do
    facts = solve.facts || []

    if facts == [] do
      {:tuple, l, [{:atom, l, :reply}, {:atom, l, :ok}, {:var, l, state_var}]}
    else
      field_names = Enum.map(solve.bindings, fn {field, _} -> field end)
      bound_set = MapSet.new(solve.bound_fields || [])

      # Build fact tuples
      fact_forms = Enum.map(facts, fn fact ->
        values = Enum.map(field_names, fn field ->
          case Keyword.get(fact, field) do
            {:atom, v} -> {:atom, l, v}
            {:integer, v} -> {:integer, l, v}
            {:var, v} -> value_to_erl({:param, v}, l, map_var)
            v when is_atom(v) -> {:atom, l, v}
            v when is_integer(v) -> {:integer, l, v}
            nil -> {:atom, l, nil}
          end
        end)
        {:tuple, l, values}
      end)
      facts_list = list_to_erl(fact_forms, l)

      # Pattern for matching: {F0, F1, F2, ...}
      match_fields = Enum.with_index(field_names) |> Enum.map(fn {_name, idx} ->
        {:var, l, :"VorF#{idx}"}
      end)
      fact_pattern = {:tuple, l, match_fields}

      # Filter condition: only compare BOUND fields
      conditions = solve.bindings
      |> Enum.with_index()
      |> Enum.flat_map(fn {{field, val}, idx} ->
        if MapSet.member?(bound_set, field) do
          var = {:var, l, :"VorF#{idx}"}
          case val do
            {:var, bound_var} -> [{:op, l, :==, var, {:var, l, erl_var(bound_var)}}]
            {:integer, n} -> [{:op, l, :==, var, {:integer, l, n}}]
            {:atom, a} -> [{:op, l, :==, var, {:atom, l, a}}]
            _ -> []
          end
        else
          []
        end
      end)

      filter_cond = case conditions do
        [] -> {:atom, l, true}
        [c] -> c
        [first | rest] -> Enum.reduce(rest, first, fn c, acc -> {:op, l, :andalso, acc, c} end)
      end

      filter_call = {:call, l,
        {:remote, l, {:atom, l, :lists}, {:atom, l, :filter}},
        [{:fun, l, {:clauses, [{:clause, l, [fact_pattern], [], [filter_cond]}]}}, facts_list]}

      # On match: bind ALL fact fields as variables, then execute body
      body_compiled = compile_handler_body(solve.body_actions, l, map_var)

      # Bind unbound fields from the matching fact
      match_binds = solve.bindings
      |> Enum.with_index()
      |> Enum.flat_map(fn {{field, val}, idx} ->
        if not MapSet.member?(bound_set, field) do
          var_name = case val do
            {:var, v} -> erl_var(v)
            _ -> erl_var(field)
          end
          [{:match, l, {:var, l, var_name}, {:var, l, :"VorF#{idx}"}}]
        else
          []
        end
      end)

      first_match_pattern = {:cons, l, fact_pattern, {:var, l, :_}}
      match_clause = {:clause, l, [first_match_pattern], [], match_binds ++ body_compiled}
      no_match_clause = {:clause, l, [{:nil, l}], [],
        [{:tuple, l, [{:atom, l, :reply}, {:atom, l, :ok}, {:var, l, state_var}]}]}

      {:case, l, filter_call, [match_clause, no_match_clause]}
    end
  end

  defp compile_equation_solve(%IR.SolveAction{} = solve, l, map_var, _state_var) do
    [bound_field] = solve.bound_fields
    [unbound_field] = solve.unbound_fields

    # Get the bound value from the bindings
    {_, bound_val} = Enum.find(solve.bindings, fn {f, _} -> f == bound_field end)
    bound_erl = case bound_val do
      {:var, v} -> {:var, l, erl_var(v)}
      {:integer, n} -> {:integer, l, n}
      {:atom, a} -> {:atom, l, a}
    end

    # Invert the equation to solve for the unbound field
    {:ok, {:assign, _, expr}} = Vor.Solver.invert(solve.equation, unbound_field)

    # Generate the arithmetic expression, substituting the bound field
    result_erl = solver_expr_to_erl(expr, l, bound_field, bound_erl)

    # Bind the unbound variable
    {_, unbound_val} = Enum.find(solve.bindings, fn {f, _} -> f == unbound_field end)
    unbound_var_name = case unbound_val do
      {:var, v} -> erl_var(v)
      _ -> erl_var(unbound_field)
    end

    bind = {:match, l, {:var, l, unbound_var_name}, result_erl}

    # Compile the solve body
    body_compiled = compile_handler_body(solve.body_actions, l, map_var)

    # Return a block: bind variable, then execute body
    {:block, l, [bind | body_compiled]}
  end

  defp solver_expr_to_erl({:ref, name}, l, bound_field, bound_erl) do
    if name == bound_field do
      bound_erl
    else
      {:var, l, erl_var(name)}
    end
  end
  defp solver_expr_to_erl({:add, left, right}, l, bf, be) do
    {:op, l, :+, solver_expr_to_erl(left, l, bf, be), solver_expr_to_erl(right, l, bf, be)}
  end
  defp solver_expr_to_erl({:sub, left, right}, l, bf, be) do
    {:op, l, :-, solver_expr_to_erl(left, l, bf, be), solver_expr_to_erl(right, l, bf, be)}
  end
  defp solver_expr_to_erl({:mul, left, right}, l, bf, be) do
    {:op, l, :*, solver_expr_to_erl(left, l, bf, be), solver_expr_to_erl(right, l, bf, be)}
  end
  defp solver_expr_to_erl({:div, left, right}, l, bf, be) do
    {:op, l, :div, solver_expr_to_erl(left, l, bf, be), solver_expr_to_erl(right, l, bf, be)}
  end
  defp solver_expr_to_erl(n, l, _bf, _be) when is_number(n), do: {:integer, l, n}

  defp action_to_erl(%IR.Action{type: :extern_call, data: %IR.ExternCallAction{} = ext}, l, map_var) do
    # Resolve the module atom for the call
    mod_atom = case ext.module do
      {:erlang_mod, m} -> m
      m -> m  # Elixir modules already have the Elixir. prefix from Module.concat
    end

    # Build argument list — extract values from keyword args
    arg_forms = Enum.map(ext.args, fn
      {_field, ref} -> value_to_erl(ref, l, map_var)
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

  defp action_to_erl(%IR.Action{type: :var_binding, data: %IR.VarBindingAction{name: name, expr: expr}}, l, map_var) do
    [{:match, l, {:var, l, erl_var(name)}, expr_to_erl(expr, l, map_var)}]
  end

  defp action_to_erl(%IR.Action{type: :send, data: %IR.SendAction{target: target, tag: tag, fields: fields}}, l, map_var) do
    # Build the message tuple
    msg_pairs = Enum.map(fields, fn
      {field, ref} -> {:map_field_assoc, l, {:atom, l, field}, value_to_erl(ref, l, map_var)}
    end)
    msg = {:tuple, l, [{:atom, l, tag}, {:map, l, msg_pairs}]}

    # Look up registry name from Data/State map
    registry_ref = {:call, l, {:remote, l, {:atom, l, :maps}, {:atom, l, :get}},
      [{:atom, l, :__vor_registry__}, {:var, l, map_var}]}

    # Via tuple: {:via, Registry, {RegistryName, target}}
    via = {:tuple, l, [
      {:atom, l, :via},
      {:atom, l, Registry},
      {:tuple, l, [registry_ref, {:atom, l, target}]}
    ]}

    # gen_server:cast(Via, Message)
    cast_call = {:call, l,
      {:remote, l, {:atom, l, :gen_server}, {:atom, l, :cast}},
      [via, msg]}

    [cast_call]
  end

  defp action_to_erl(_action, _l, _map_var), do: []

  defp list_to_erl([], l), do: {:nil, l}
  defp list_to_erl([h | t], l), do: {:cons, l, h, list_to_erl(t, l)}
end
