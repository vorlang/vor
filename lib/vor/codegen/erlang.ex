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
      gen_handle_info(agent, l)
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

    # Compile init handler body if present
    {init_handler_exprs, init_data_var} = compile_init_handler_body(agent.init_handler, l, :Data)

    timer_setup = gen_periodic_timer_setup(agent.periodic_timers || [], l, init_data_var)

    # Build init body that extracts system metadata if present
    body = gen_init_with_metadata(init_map, l, fn _data_var ->
      {:tuple, l, [{:atom, l, :ok}, {:var, l, init_data_var}]}
    end)

    # Insert init handler + timer setup before the final return
    inserts = init_handler_exprs ++ timer_setup
    body = case inserts do
      [] -> body
      _ ->
        {pre, [ret]} = Enum.split(body, -1)
        pre ++ inserts ++ [ret]
    end

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

  defp gen_handle_info(agent, l) do
    timer_clauses = Enum.map(agent.periodic_timers || [], fn timer ->
      # Compile timer body — generate side effects only (transitions, send, broadcast)
      {pre_actions, _terminal} = split_terminal(timer.actions)
      {transitions, other_pre} = Enum.split_with(pre_actions, fn a -> a.type == :transition end)
      pre_exprs = Enum.flat_map(other_pre, &action_to_erl(&1, l, :State))
      {state_update_exprs, state_var} = gen_server_state_updates(transitions, l)

      # Re-arm timer
      interval_form = case timer.interval do
        {:integer, n} -> {:integer, l, n}
        {:param, name} -> {:call, l, {:remote, l, {:atom, l, :maps}, {:atom, l, :get}},
          [{:atom, l, name}, {:var, l, state_var}]}
      end

      rearm = {:call, l, {:remote, l, {:atom, l, :erlang}, {:atom, l, :send_after}},
        [interval_form, {:call, l, {:atom, l, :self}, []}, {:atom, l, timer.tag}]}

      result = {:tuple, l, [{:atom, l, :noreply}, {:var, l, state_var}]}

      {:clause, l, [{:atom, l, timer.tag}, {:var, l, :State}], [],
        pre_exprs ++ state_update_exprs ++ [rearm, result]}
    end)

    catchall = {:clause, l, [{:var, l, :_Msg}, {:var, l, :State}], [],
      [{:tuple, l, [{:atom, l, :noreply}, {:var, l, :State}]}]}

    {:function, l, :handle_info, 2, timer_clauses ++ [catchall]}
  end

  # Compile a handler's action list into Erlang body expressions for gen_server
  defp compile_handler_body(actions, l, map_var) do
    {pre_actions, terminal} = split_terminal(actions)

    # Process actions sequentially, threading state variable through transitions
    {pre_exprs, current_var} = Enum.reduce(pre_actions, {[], map_var}, fn action, {exprs, sv} ->
      case action do
        %IR.Action{type: :transition, data: %IR.TransitionAction{field: field, value: value}} ->
          new_sv = :"VorGS#{length(exprs)}"
          update = {:match, l, {:var, l, new_sv},
            {:map, l, {:var, l, sv}, [
              {:map_field_exact, l, {:atom, l, field}, transition_value_to_erl(value, l, sv)}
            ]}}
          {exprs ++ [update], new_sv}
        _ ->
          {exprs ++ action_to_erl(action, l, sv), sv}
      end
    end)

    state_var = current_var
    emit_map_var = current_var

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

    pre_exprs ++ [terminal_expr]
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
  defp transition_value_to_erl({:map_op, op, args}, l, map_var), do: map_op_to_erl(op, args, l, map_var)
  defp transition_value_to_erl({:minmax, op, left, right}, l, map_var) do
    {:call, l, {:atom, l, op}, [value_to_erl(left, l, map_var), value_to_erl(right, l, map_var)]}
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
  defp value_to_erl({:map_op, op, args}, l, map_var) do
    map_op_to_erl(op, args, l, map_var)
  end
  defp value_to_erl({:minmax, op, left, right}, l, map_var) do
    {:call, l, {:atom, l, op}, [value_to_erl(left, l, map_var), value_to_erl(right, l, map_var)]}
  end
  defp value_to_erl({:list, elements}, l, map_var) do
    elements
    |> Enum.reverse()
    |> Enum.reduce({:nil, l}, fn elem, acc ->
      {:cons, l, value_to_erl(elem, l, map_var), acc}
    end)
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

    connections_lookup = {:call, l,
      {:remote, l, {:atom, l, :proplists}, {:atom, l, :get_value}},
      [{:atom, l, :__vor_connections__}, {:var, l, :Args}, {:nil, l}]}

    data_with_meta = {:map, l, {:var, l, :Data0}, [
      {:map_field_assoc, l, {:atom, l, :__vor_registry__}, {:var, l, :VorRegistry}},
      {:map_field_assoc, l, {:atom, l, :__vor_name__}, {:var, l, :VorName}},
      {:map_field_assoc, l, {:atom, l, :__vor_connections__}, {:var, l, :VorConnections}}
    ]}

    name_bind = {:match, l, {:var, l, :VorName}, name_lookup}
    connections_bind = {:match, l, {:var, l, :VorConnections}, connections_lookup}

    case_expr = {:case, l, registry_lookup, [
      {:clause, l, [{:atom, l, :undefined}], [],
        [{:var, l, :Data0}]},
      {:clause, l, [{:var, l, :VorRegistry}], [],
        [name_bind, connections_bind, data_with_meta]}
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

    # Check if initial state needs a state_timeout for liveness monitoring
    monitors = agent.monitors || []
    init_timeout_acts = state_timeout_actions(initial_state, monitors, l)

    # Compile init handler body if present
    {init_handler_exprs, init_data_var} = compile_init_handler_body(agent.init_handler, l, :Data)

    # Build init body that extracts system metadata if present
    body = gen_init_with_metadata(init_map, l, fn _data_var ->
      case init_timeout_acts do
        [] ->
          {:tuple, l, [
            {:atom, l, :ok},
            {:atom, l, initial_state},
            {:var, l, init_data_var}
          ]}
        _ ->
          {:tuple, l, [
            {:atom, l, :ok},
            {:atom, l, initial_state},
            {:var, l, init_data_var},
            list_to_erl(init_timeout_acts, l)
          ]}
      end
    end)

    timer_setup = gen_periodic_timer_setup(agent.periodic_timers || [], l, init_data_var)

    inserts = init_handler_exprs ++ timer_setup
    body = case inserts do
      [] -> body
      _ ->
        {pre, [ret]} = Enum.split(body, -1)
        pre ++ inserts ++ [ret]
    end

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

    _data_field_names = MapSet.new((agent.data_fields || []), fn %IR.DataField{name: name} -> name end)

    # Generate cast clauses and corresponding call clauses
    {cast_clauses, call_clauses} =
      agent.handlers
      |> Enum.reject(fn h -> is_timeout_handler?(h, monitors) end)
      |> Enum.map(fn handler ->
        pattern_form = pattern_to_erl(handler.pattern, l)
        guard_erl = statem_guard_to_erl(handler.guard, l)

        # Build cast and call handler bodies using the new data-threading codegen
        cast_body = compile_statem_handler_body(
          handler.actions, l, :Data, 0, state_field_name, monitors, nil)

        cast_clause = {:clause, l,
          [{:atom, l, :cast}, pattern_form, {:var, l, :State}, {:var, l, :Data}],
          guard_erl,
          cast_body}

        call_body = compile_statem_handler_body(
          handler.actions, l, :Data, 0, state_field_name, monitors, {:call, :From})

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

    # Periodic timer info handlers
    periodic_clauses = gen_periodic_timer_statem_clauses(agent, l, state_field_name, monitors)

    {:function, l, :handle_event, 4, cast_clauses ++ call_clauses ++ guarded_catchalls ++ timer_clauses ++ timeout_clauses ++ periodic_clauses ++ [catchall]}
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
    state_field_name = case agent.state_fields do
      [%IR.StateField{name: name} | _] -> name
      _ -> :phase
    end

    timeout_handlers = agent.handlers
    |> Enum.filter(fn h -> is_timeout_handler?(h, monitors) end)

    Enum.map(timeout_handlers, fn handler ->
      monitor = Enum.find(monitors, fn m -> m.event_tag == handler.pattern.tag end)

      # Compile the full handler body using the new data-threading codegen
      body = compile_statem_handler_body(
        handler.actions, l, :Data, 0, state_field_name, monitors, nil)

      excluded = [monitor.target_state | monitor.excluded_states]
      guard = excluded
      |> Enum.uniq()
      |> Enum.map(fn s -> {:op, l, :"/=", {:var, l, :State}, {:atom, l, s}} end)

      {:clause, l,
        [{:atom, l, :state_timeout}, {:atom, l, handler.pattern.tag}, {:var, l, :State}, {:var, l, :Data}],
        [guard],
        body}
    end)
  end

  # Compile init handler body into expressions that update the Data variable
  # Returns {exprs, final_data_var} — the final data var replaces the original in the return
  defp compile_init_handler_body(nil, _l, data_var), do: {[], data_var}
  defp compile_init_handler_body(%IR.Handler{actions: actions}, l, data_var) do
    {pre_actions, _terminal} = split_terminal(actions)
    {transitions, other_pre} = Enum.split_with(pre_actions, fn a -> a.type == :transition end)

    pre_exprs = Enum.flat_map(other_pre, &action_to_erl(&1, l, data_var))

    case transitions do
      [] -> {pre_exprs, data_var}
      _ ->
        map_pairs = Enum.map(transitions, fn %IR.Action{type: :transition, data: %IR.TransitionAction{field: field, value: value}} ->
          {:map_field_exact, l, {:atom, l, field}, transition_value_to_erl(value, l, data_var)}
        end)
        new_var = :VorInitData
        update = {:match, l, {:var, l, new_var}, {:map, l, {:var, l, data_var}, map_pairs}}
        {pre_exprs ++ [update], new_var}
    end
  end

  # Generate send_after calls for periodic timers in init
  defp gen_periodic_timer_setup([], _l, _data_var), do: []
  defp gen_periodic_timer_setup(timers, l, data_var) do
    Enum.map(timers, fn timer ->
      interval_form = case timer.interval do
        {:integer, n} -> {:integer, l, n}
        {:param, name} ->
          {:call, l, {:remote, l, {:atom, l, :maps}, {:atom, l, :get}},
            [{:atom, l, name}, {:var, l, data_var}]}
      end

      {:call, l, {:remote, l, {:atom, l, :erlang}, {:atom, l, :send_after}},
        [interval_form, {:call, l, {:atom, l, :self}, []}, {:atom, l, timer.tag}]}
    end)
  end

  # Generate handle_event(info, ...) clauses for periodic timers in gen_statem
  defp gen_periodic_timer_statem_clauses(agent, l, state_field_name, monitors) do
    Enum.map(agent.periodic_timers || [], fn timer ->
      body = compile_statem_handler_body(
        timer.actions, l, :Data, 0, state_field_name, monitors, nil)

      # Re-arm timer
      interval_form = case timer.interval do
        {:integer, n} -> {:integer, l, n}
        {:param, name} ->
          {:call, l, {:remote, l, {:atom, l, :maps}, {:atom, l, :get}},
            [{:atom, l, name}, {:var, l, :Data}]}
      end

      rearm = {:call, l, {:remote, l, {:atom, l, :erlang}, {:atom, l, :send_after}},
        [interval_form, {:call, l, {:atom, l, :self}, []}, {:atom, l, timer.tag}]}

      # Replace the return tuple to include rearm
      # The body ends with {next_state, State, Data, Actions}
      # Insert rearm before the return
      {pre, [ret]} = Enum.split(body, -1)

      {:clause, l,
        [{:atom, l, :info}, {:atom, l, timer.tag}, {:var, l, :State}, {:var, l, :Data}],
        [],
        pre ++ [rearm, ret]}
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

  # Compile a gen_statem handler body with data map threading.
  # Returns a list of Erlang expressions ending in a {next_state, ...} or {keep_state, ...} return.
  # `data_var` is the current data map variable name (e.g., :Data, :VorData1, :VorData2).
  # `counter` is used for unique variable names.
  # `state_field_name` is the enum state field name.
  # `monitors` is for generating state_timeout actions.
  # `call_info` is nil for cast, or {:call, from_var} for call (to include reply action).
  defp compile_statem_handler_body(actions, l, data_var, counter, state_field_name, monitors, call_info) do
    {exprs, has_terminal} =
      compile_statem_actions_v2(actions, l, data_var, counter, state_field_name, monitors, call_info)

    if has_terminal do
      # A conditional already generated all returns inside its branches
      exprs
    else
      # Linear path — need to generate return at the end
      # Extract the final data var and state from the generated expressions
      {final_data_var, new_state, emit_form} =
        extract_final_state(actions, l, data_var, counter, state_field_name)

      state_result = case new_state do
        nil -> {:var, l, :State}
        value when is_atom(value) -> {:atom, l, value}
      end

      timeout_acts = state_timeout_actions(new_state, monitors, l)

      case call_info do
        nil ->
          actions_list = list_to_erl(timeout_acts, l)
          exprs ++ [{:tuple, l, [{:atom, l, :next_state}, state_result, {:var, l, final_data_var}, actions_list]}]

        {:call, from_var} ->
          reply_value = emit_form || {:atom, l, :ok}
          reply_action = {:tuple, l, [{:atom, l, :reply}, {:var, l, from_var}, reply_value]}
          actions_list = list_to_erl([reply_action | timeout_acts], l)
          exprs ++ [{:tuple, l, [{:atom, l, :next_state}, state_result, {:var, l, final_data_var}, actions_list]}]
      end
    end
  end

  # Extract final data variable name, state, and emit from a linear action sequence
  defp extract_final_state(actions, _l, data_var, counter, state_field_name) do
    Enum.reduce(actions, {data_var, nil, nil, counter}, fn action, {dv, state, emit, c} ->
      case action do
        %IR.Action{type: :transition, data: %IR.TransitionAction{field: field, value: value}} ->
          if field == state_field_name and is_atom(value) do
            {dv, value, emit, c}
          else
            {:"VorData#{c}", state, emit, c + 1}
          end
        %IR.Action{type: :emit, data: %IR.EmitAction{}} ->
          {dv, state, :has_emit, c}
        _ ->
          {dv, state, emit, c}
      end
    end)
    |> then(fn {dv, state, emit_marker, _c} ->
      emit_form = if emit_marker == :has_emit do
        # Find and compile the emit
        emit_action = Enum.find(actions, fn a -> a.type == :emit end)
        if emit_action, do: emit_to_erl(emit_action.data, 1, dv), else: nil
      else
        nil
      end
      {dv, state, emit_form}
    end)
  end

  # Compile actions producing {exprs, has_terminal_conditional}
  # When a conditional is encountered, it generates complete returns inside each branch
  defp compile_statem_actions_v2(actions, l, data_var, counter, state_field_name, monitors, call_info) do
    {exprs, _dv, _c, has_terminal} =
      Enum.reduce(actions, {[], data_var, counter, false}, fn action, {exprs, dv, c, terminal} ->
        if terminal do
          # Already generated a terminal conditional — skip remaining
          {exprs, dv, c, true}
        else
          case action do
            %IR.Action{type: :transition, data: %IR.TransitionAction{field: field, value: value}} ->
              if field == state_field_name and is_atom(value) do
                # State transition — track in accumulator but don't generate code
                {exprs, dv, c, false}
              else
                new_dv = :"VorData#{c}"
                val_form = transition_value_to_erl(value, l, dv)
                update = {:match, l, {:var, l, new_dv},
                  {:map, l, {:var, l, dv}, [
                    {:map_field_exact, l, {:atom, l, field}, val_form}
                  ]}}
                {exprs ++ [update], new_dv, c + 1, false}
              end

            %IR.Action{type: :var_binding, data: %IR.VarBindingAction{name: name, expr: expr}} ->
              binding = {:match, l, {:var, l, erl_var(name)}, expr_to_erl(expr, l, dv)}
              {exprs ++ [binding], dv, c, false}

            %IR.Action{type: :extern_call} = ext ->
              ext_exprs = action_to_erl(ext, l, dv)
              {exprs ++ ext_exprs, dv, c, false}

            %IR.Action{type: :send} = send ->
              send_exprs = action_to_erl(send, l, dv)
              {exprs ++ send_exprs, dv, c, false}

            %IR.Action{type: :broadcast} = bcast ->
              bcast_exprs = action_to_erl(bcast, l, dv)
              {exprs ++ bcast_exprs, dv, c, false}

            %IR.Action{type: :emit} ->
              # Emit is handled in the return generation, skip here
              {exprs, dv, c, false}

            %IR.Action{type: :conditional, data: %IR.ConditionalAction{condition: cond_ir, then_actions: ta, else_actions: ea}} ->
              # Terminal: generate case with complete returns in each branch
              cond_form = condition_to_erl(cond_ir, l, dv)

              # Get remaining actions after this conditional
              idx = Enum.find_index(actions, fn a -> a == action end) || 0
              rest = Enum.drop(actions, idx + 1)

              then_body = compile_statem_handler_body(ta ++ rest, l, dv, c, state_field_name, monitors, call_info)
              else_body = compile_statem_handler_body(ea ++ rest, l, dv, c + 100, state_field_name, monitors, call_info)

              case_expr = {:case, l, cond_form, [
                {:clause, l, [{:atom, l, true}], [], then_body},
                {:clause, l, [{:atom, l, false}], [], else_body}
              ]}

              {exprs ++ [case_expr], dv, c + 200, true}

            _ ->
              {exprs, dv, c, false}
          end
        end
      end)

    {exprs, has_terminal}
  end


  # Legacy compile_statem_body - kept for timeout handlers and other non-handler contexts
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

          %IR.Action{type: :broadcast, data: %IR.BroadcastAction{}} = action ->
            broadcast_exprs = action_to_erl(action, l, :Data)
            {exprs ++ broadcast_exprs, state, updates, emit}

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
  defp expr_to_erl({:map_op, op, args}, l, map_var), do: map_op_to_erl(op, args, l, map_var)
  defp expr_to_erl({:minmax, op, left, right}, l, map_var) do
    {:call, l, {:atom, l, op}, [value_to_erl(left, l, map_var), value_to_erl(right, l, map_var)]}
  end

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
      {field, {:list, _} = list_val} ->
        {:map_field_assoc, l, {:atom, l, field}, value_to_erl(list_val, l, map_var)}
      {field, {:map_op, _, _} = mop} ->
        {:map_field_assoc, l, {:atom, l, field}, value_to_erl(mop, l, map_var)}
      {field, {:minmax, _, _, _} = mm} ->
        {:map_field_assoc, l, {:atom, l, field}, value_to_erl(mm, l, map_var)}
    end)

    {:tuple, l, [{:atom, l, tag}, {:map, l, map_pairs}]}
  end

  # Map operation codegen helpers
  defp map_op_to_erl(:map_get, [map_ref, key, default], l, map_var) do
    map_erl = value_to_erl(map_ref, l, map_var)
    {:call, l, {:remote, l, {:atom, l, :maps}, {:atom, l, :get}},
      [value_to_erl(key, l, map_var), map_erl, value_to_erl(default, l, map_var)]}
  end

  defp map_op_to_erl(:map_put, [map_ref, key, val], l, map_var) do
    map_erl = value_to_erl(map_ref, l, map_var)
    {:call, l, {:remote, l, {:atom, l, :maps}, {:atom, l, :put}},
      [value_to_erl(key, l, map_var), value_to_erl(val, l, map_var), map_erl]}
  end

  defp map_op_to_erl(:map_has, [map_ref, key], l, map_var) do
    map_erl = value_to_erl(map_ref, l, map_var)
    # Return :true or :false atoms for Vor compatibility
    {:call, l, {:remote, l, {:atom, l, :maps}, {:atom, l, :is_key}},
      [value_to_erl(key, l, map_var), map_erl]}
  end

  defp map_op_to_erl(:map_delete, [map_ref, key], l, map_var) do
    map_erl = value_to_erl(map_ref, l, map_var)
    {:call, l, {:remote, l, {:atom, l, :maps}, {:atom, l, :remove}},
      [value_to_erl(key, l, map_var), map_erl]}
  end

  defp map_op_to_erl(:map_size, [map_ref], l, map_var) do
    map_erl = value_to_erl(map_ref, l, map_var)
    {:call, l, {:remote, l, {:atom, l, :maps}, {:atom, l, :size}},
      [map_erl]}
  end

  defp map_op_to_erl(:map_sum, [map_ref], l, map_var) do
    map_erl = value_to_erl(map_ref, l, map_var)
    {:call, l, {:remote, l, {:atom, l, :lists}, {:atom, l, :sum}},
      [{:call, l, {:remote, l, {:atom, l, :maps}, {:atom, l, :values}},
        [map_erl]}]}
  end

  defp map_op_to_erl(:map_merge, [map1, map2, {:atom, strategy}], l, map_var) do
    map1_erl = value_to_erl(map1, l, map_var)
    map2_erl = value_to_erl(map2, l, map_var)
    merge_fun = case strategy do
      :max -> {:fun, l, {:clauses, [{:clause, l, [{:var, l, :_K}, {:var, l, :V1}, {:var, l, :V2}], [], [{:call, l, {:atom, l, :max}, [{:var, l, :V1}, {:var, l, :V2}]}]}]}}
      :min -> {:fun, l, {:clauses, [{:clause, l, [{:var, l, :_K}, {:var, l, :V1}, {:var, l, :V2}], [], [{:call, l, {:atom, l, :min}, [{:var, l, :V1}, {:var, l, :V2}]}]}]}}
      :sum -> {:fun, l, {:clauses, [{:clause, l, [{:var, l, :_K}, {:var, l, :V1}, {:var, l, :V2}], [], [{:op, l, :+, {:var, l, :V1}, {:var, l, :V2}}]}]}}
      :replace -> {:fun, l, {:clauses, [{:clause, l, [{:var, l, :_K}, {:var, l, :_V1}, {:var, l, :V2}], [], [{:var, l, :V2}]}]}}
      :lww ->
        # Last-Writer-Wins: compare timestamps, tiebreak by node_id
        # fun(_K, V1, V2) ->
        #   T1 = maps:get(timestamp, V1, 0), T2 = maps:get(timestamp, V2, 0),
        #   if T1 > T2 -> V1; T1 < T2 -> V2; else -> compare node_id
        t1 = {:call, l, {:remote, l, {:atom, l, :maps}, {:atom, l, :get}},
          [{:atom, l, :timestamp}, {:var, l, :VorLwwV1}, {:integer, l, 0}]}
        t2 = {:call, l, {:remote, l, {:atom, l, :maps}, {:atom, l, :get}},
          [{:atom, l, :timestamp}, {:var, l, :VorLwwV2}, {:integer, l, 0}]}
        n1 = {:call, l, {:remote, l, {:atom, l, :maps}, {:atom, l, :get}},
          [{:atom, l, :node_id}, {:var, l, :VorLwwV1}, {:atom, l, :_}]}
        n2 = {:call, l, {:remote, l, {:atom, l, :maps}, {:atom, l, :get}},
          [{:atom, l, :node_id}, {:var, l, :VorLwwV2}, {:atom, l, :_}]}

        node_cmp = {:case, l, {:op, l, :>=, n1, n2}, [
          {:clause, l, [{:atom, l, true}], [], [{:var, l, :VorLwwV1}]},
          {:clause, l, [{:atom, l, false}], [], [{:var, l, :VorLwwV2}]}
        ]}

        time_cmp = {:case, l, {:op, l, :>, t1, t2}, [
          {:clause, l, [{:atom, l, true}], [], [{:var, l, :VorLwwV1}]},
          {:clause, l, [{:atom, l, false}], [],
            [{:case, l, {:op, l, :<, t1, t2}, [
              {:clause, l, [{:atom, l, true}], [], [{:var, l, :VorLwwV2}]},
              {:clause, l, [{:atom, l, false}], [], [node_cmp]}
            ]}]}
        ]}

        {:fun, l, {:clauses, [{:clause, l, [{:var, l, :_K}, {:var, l, :VorLwwV1}, {:var, l, :VorLwwV2}], [], [time_cmp]}]}}
    end
    {:call, l, {:remote, l, {:atom, l, :maps}, {:atom, l, :merge_with}},
      [merge_fun, map1_erl, map2_erl]}
  end

  # --- List operation codegen ---

  defp map_op_to_erl(:list_head, [list_ref], l, map_var) do
    list_erl = value_to_erl(list_ref, l, map_var)
    {:case, l, list_erl, [
      {:clause, l, [{:cons, l, {:var, l, :VorListH}, {:var, l, :_}}], [], [{:var, l, :VorListH}]},
      {:clause, l, [{:nil, l}], [], [{:atom, l, :none}]}
    ]}
  end

  defp map_op_to_erl(:list_tail, [list_ref], l, map_var) do
    list_erl = value_to_erl(list_ref, l, map_var)
    {:case, l, list_erl, [
      {:clause, l, [{:cons, l, {:var, l, :_}, {:var, l, :VorListT}}], [], [{:var, l, :VorListT}]},
      {:clause, l, [{:nil, l}], [], [{:nil, l}]}
    ]}
  end

  defp map_op_to_erl(:list_append, [list_ref, value], l, map_var) do
    list_erl = value_to_erl(list_ref, l, map_var)
    val_erl = value_to_erl(value, l, map_var)
    {:op, l, :++, list_erl, {:cons, l, val_erl, {:nil, l}}}
  end

  defp map_op_to_erl(:list_prepend, [list_ref, value], l, map_var) do
    list_erl = value_to_erl(list_ref, l, map_var)
    val_erl = value_to_erl(value, l, map_var)
    {:cons, l, val_erl, list_erl}
  end

  defp map_op_to_erl(:list_length, [list_ref], l, map_var) do
    list_erl = value_to_erl(list_ref, l, map_var)
    {:call, l, {:atom, l, :length}, [list_erl]}
  end

  defp map_op_to_erl(:list_empty, [list_ref], l, map_var) do
    list_erl = value_to_erl(list_ref, l, map_var)
    {:case, l, list_erl, [
      {:clause, l, [{:nil, l}], [], [{:atom, l, true}]},
      {:clause, l, [{:var, l, :_}], [], [{:atom, l, false}]}
    ]}
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
        # Use map_get/2 which is a guard-safe BIF (OTP 21+)
        {:call, l, {:atom, l, :map_get},
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

    # Wrap in try/catch with unique variable names per extern call
    # Use bind var (if any) + function name for uniqueness
    bind_suffix = if ext.bind, do: "_#{ext.bind}", else: "_#{:erlang.unique_integer([:positive])}"
    suffix = :"#{ext.function}#{bind_suffix}"
    class_var = :"VorClass_#{suffix}"
    reason_var = :"VorReason_#{suffix}"
    stack_var = :"VorStack_#{suffix}"

    try_form = {:try, l,
      [call_form],  # body
      [],           # case clauses (none)
      [             # catch clauses
        {:clause, l,
          [{:tuple, l, [{:var, l, class_var}, {:var, l, reason_var}, {:var, l, stack_var}]}],
          [],
          [{:tuple, l, [
            {:atom, l, :vor_extern_error},
            {:var, l, class_var},
            {:var, l, reason_var},
            {:var, l, stack_var}
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

    # Target can be a literal atom or a bound variable
    target_form = case target do
      {:bound_var, var} -> {:var, l, erl_var(var)}
      atom when is_atom(atom) -> {:atom, l, atom}
    end

    # Safe send: check if registry exists, skip if standalone agent
    registry_lookup = {:call, l, {:remote, l, {:atom, l, :maps}, {:atom, l, :get}},
      [{:atom, l, :__vor_registry__}, {:var, l, map_var}, {:atom, l, :undefined}]}

    registry_send = {:call, l,
      {:remote, l, {:atom, l, :gen_server}, {:atom, l, :cast}},
      [{:tuple, l, [
        {:atom, l, :via},
        {:atom, l, Registry},
        {:tuple, l, [{:var, l, :VorSendReg}, target_form]}
      ]}, msg]}

    safe_send = {:case, l, registry_lookup, [
      {:clause, l, [{:atom, l, :undefined}], [], [{:atom, l, :ok}]},
      {:clause, l, [{:var, l, :VorSendReg}], [], [registry_send]}
    ]}

    [safe_send]
  end

  defp action_to_erl(%IR.Action{type: :broadcast, data: %IR.BroadcastAction{tag: tag, fields: fields}}, l, map_var) do
    # Build the message tuple
    msg_pairs = Enum.map(fields, fn
      {field, ref} -> {:map_field_assoc, l, {:atom, l, field}, value_to_erl(ref, l, map_var)}
    end)
    msg = {:tuple, l, [{:atom, l, tag}, {:map, l, msg_pairs}]}

    # Get connections and registry from data map (default to empty list for standalone agents)
    connections_ref = {:call, l, {:remote, l, {:atom, l, :maps}, {:atom, l, :get}},
      [{:atom, l, :__vor_connections__}, {:var, l, map_var}, {:nil, l}]}
    registry_ref = {:call, l, {:remote, l, {:atom, l, :maps}, {:atom, l, :get}},
      [{:atom, l, :__vor_registry__}, {:var, l, map_var}]}

    # lists:foreach(fun(Peer) ->
    #   case Registry:lookup(Registry, Peer) of
    #     [{Pid, _}] -> gen_server:cast(Pid, Message);
    #     [] -> ok
    #   end
    # end, Connections)
    peer_var = {:var, l, :VorBroadcastPeer}
    pid_var = {:var, l, :VorBroadcastPid}

    lookup_call = {:call, l,
      {:remote, l, {:atom, l, Registry}, {:atom, l, :lookup}},
      [registry_ref, peer_var]}

    cast_call = {:call, l,
      {:remote, l, {:atom, l, :gen_server}, {:atom, l, :cast}},
      [pid_var, msg]}

    case_expr = {:case, l, lookup_call, [
      {:clause, l,
        [{:cons, l, {:tuple, l, [pid_var, {:var, l, :_}]}, {:var, l, :_}}],
        [],
        [cast_call]},
      {:clause, l,
        [{:var, l, :_}],
        [],
        [{:atom, l, :ok}]}
    ]}

    foreach_fun = {:fun, l, {:clauses, [{:clause, l, [peer_var], [], [case_expr]}]}}

    foreach_call = {:call, l,
      {:remote, l, {:atom, l, :lists}, {:atom, l, :foreach}},
      [foreach_fun, {:var, l, :VorBroadcastConns}]}

    # Safe broadcast: skip if connections is nil (standalone agent)
    safe_broadcast = {:case, l, connections_ref, [
      {:clause, l, [{:atom, l, nil}], [], [{:atom, l, :ok}]},
      {:clause, l, [{:nil, l}], [], [{:atom, l, :ok}]},
      {:clause, l, [{:var, l, :VorBroadcastConns}], [], [foreach_call]}
    ]}

    [safe_broadcast]
  end

  defp action_to_erl(_action, _l, _map_var), do: []

  defp list_to_erl([], l), do: {:nil, l}
  defp list_to_erl([h | t], l), do: {:cons, l, h, list_to_erl(t, l)}
end
