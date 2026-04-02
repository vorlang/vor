defmodule Vor.Graph do
  @moduledoc """
  State transition graph extracted from gen_statem agents.
  Used for safety invariant verification and visualization.
  """

  defstruct [:agent, :states, :initial_state, :transitions, :emit_map]

  alias Vor.IR

  @doc """
  Extract a state graph from a lowered IR agent.
  Returns `{:ok, graph}` for gen_statem agents, `:no_graph` for gen_server agents.
  """
  def extract(%IR.Agent{behaviour: :gen_server}), do: :no_graph

  def extract(%IR.Agent{behaviour: :gen_statem} = agent) do
    states = case agent.state_fields do
      [%IR.StateField{values: values} | _] -> values
      _ -> []
    end

    initial = case agent.state_fields do
      [%IR.StateField{initial: init} | _] -> init
      _ -> nil
    end

    transitions = extract_transitions(agent.handlers)
    timeout_transitions = extract_timeout_transitions(agent.monitors || [])
    emit_map = extract_emit_map(agent.handlers, states)

    {:ok, %__MODULE__{
      agent: agent.name,
      states: states,
      initial_state: initial,
      transitions: transitions ++ timeout_transitions,
      emit_map: emit_map
    }}
  end

  defp extract_timeout_transitions(monitors) do
    Enum.flat_map(monitors, fn monitor ->
      Enum.map(monitor.monitored_states, fn from ->
        %{from: from, to: monitor.target_state, trigger: :state_timeout}
      end)
    end)
  end

  defp extract_transitions(handlers) do
    Enum.flat_map(handlers, fn handler ->
      from_state = guard_state(handler.guard)
      extract_handler_transitions(handler.actions, from_state, handler.pattern.tag)
    end)
  end

  defp extract_handler_transitions(actions, from_state, trigger) do
    Enum.flat_map(actions, fn
      %IR.Action{type: :transition, data: %IR.TransitionAction{value: to}} when is_atom(to) ->
        [%{from: from_state, to: to, trigger: trigger}]

      %IR.Action{type: :conditional, data: %IR.ConditionalAction{then_actions: then_acts, else_actions: else_acts}} ->
        extract_handler_transitions(then_acts, from_state, trigger) ++
        extract_handler_transitions(else_acts, from_state, trigger)

      _ -> []
    end)
  end

  defp extract_emit_map(handlers, states) do
    base = Map.new(states, fn s -> {s, []} end)

    Enum.reduce(handlers, base, fn handler, map ->
      from_state = guard_state(handler.guard)
      emits = extract_handler_emits(handler.actions)

      case from_state do
        nil -> map
        state -> Map.update(map, state, emits, fn existing -> Enum.uniq(existing ++ emits) end)
      end
    end)
  end

  defp extract_handler_emits(actions) do
    Enum.flat_map(actions, fn
      %IR.Action{type: :emit, data: %IR.EmitAction{tag: tag}} -> [tag]

      %IR.Action{type: :conditional, data: %IR.ConditionalAction{then_actions: then_acts, else_actions: else_acts}} ->
        extract_handler_emits(then_acts) ++ extract_handler_emits(else_acts)

      _ -> []
    end)
    |> Enum.uniq()
  end

  # Extract which state a handler's guard constrains
  # Match any guard that checks a field == atom (the state field name may vary)
  defp guard_state(%IR.GuardExpr{op: :==, value: {:atom, state}}), do: state
  defp guard_state(%IR.CompoundGuardExpr{left: left}), do: guard_state(left)
  defp guard_state(_), do: nil

  @doc """
  Format the graph as human-readable text.
  """
  def to_text(%__MODULE__{} = g) do
    lines = [
      "#{g.agent} state graph",
      String.duplicate("═", String.length("#{g.agent} state graph")),
      "",
      "States: #{format_states(g)}",
      "",
      "Transitions:"
    ]

    transition_lines = Enum.map(g.transitions, fn t ->
      "  #{t.from} → #{t.to}#{format_trigger(t.trigger)}"
    end)

    emit_lines = ["", "Emits by state:"] ++
      Enum.map(g.states, fn state ->
        emits = Map.get(g.emit_map, state, [])
        tags = Enum.map_join(emits, ", ", fn tag -> "{:#{tag}, ...}" end)
        "  #{state}: #{if tags == "", do: "(none)", else: tags}"
      end)

    property_lines = ["", "Properties:"] ++ check_properties(g)

    Enum.join(lines ++ transition_lines ++ emit_lines ++ property_lines, "\n")
  end

  @doc """
  Format the graph as a Mermaid state diagram.
  """
  def to_mermaid(%__MODULE__{} = g) do
    lines = [
      "stateDiagram-v2",
      "    [*] --> #{g.initial_state}"
    ]

    transition_lines = Enum.map(g.transitions, fn t ->
      "    #{t.from} --> #{t.to} : #{t.trigger}"
    end)

    Enum.join(lines ++ transition_lines, "\n")
  end

  defp format_states(g) do
    Enum.map_join(g.states, ", ", fn state ->
      if state == g.initial_state, do: "#{state} (initial)", else: "#{state}"
    end)
  end

  defp format_trigger(trigger) when is_atom(trigger) do
    name = Atom.to_string(trigger)
    if String.ends_with?(name, "_fired") do
      " when #{String.replace_trailing(name, "_fired", "")} timer fires"
    else
      " on #{trigger}"
    end
  end
  defp format_trigger(trigger), do: " on #{inspect(trigger)}"

  defp check_properties(g) do
    reachable = reachable_states(g)
    all_reachable = MapSet.new(g.states) == reachable

    has_outgoing = Enum.all?(g.states, fn state ->
      Enum.any?(g.transitions, fn t -> t.from == state end)
    end)

    [
      "  All states reachable from initial: #{if all_reachable, do: "✓", else: "✗"}",
      "  No dead-end states: #{if has_outgoing, do: "✓", else: "—"}"
    ]
  end

  @doc """
  Find all states reachable from the initial state.
  """
  def reachable_states(%__MODULE__{} = g) do
    do_reachable(g, [g.initial_state], MapSet.new())
  end

  defp do_reachable(_g, [], visited), do: visited
  defp do_reachable(g, [state | rest], visited) do
    if MapSet.member?(visited, state) do
      do_reachable(g, rest, visited)
    else
      visited = MapSet.put(visited, state)
      next = g.transitions
             |> Enum.filter(fn t -> t.from == state end)
             |> Enum.map(fn t -> t.to end)
      do_reachable(g, next ++ rest, visited)
    end
  end
end
