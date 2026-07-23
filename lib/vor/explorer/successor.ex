defmodule Vor.Explorer.Successor do
  @moduledoc """
  Computes the successor product states from a given product state.

  Successors come from two sources:

    1. Delivering a pending message to its recipient.
    2. Protocol-driven external events — for each agent and each `accepts`
       declaration, a representative external client message is dispatched.

  After generation the successors are passed through a state-change-only
  filter: any successor whose fingerprint equals the parent's is dropped
  (no-op deliveries are skipped before they enter the visited set).
  """

  alias Vor.Explorer.{ProductState, Simulator}
  alias Vor.IR

  @doc """
  Generate the unique, state-changing successors of `ps`.

  `instance_irs` maps each agent **instance** name (e.g. `:n1`) to its
  `IR.Agent` (so the simulator can walk handlers). Multiple instances of the
  same agent type share the same IR object.

  `system_ir` carries the connection topology used by `broadcast`.

  Optional `opts`:

    * `:relevance` — per-instance relevance map from `Vor.Explorer.Relevance`.
      When supplied, abstracted state fields are masked with `:abstracted`
      after every successor is computed so the visited set can collapse
      irrelevant variation.
    * `:integer_bound` — saturation cap (default 3). Tracked integer fields
      are clamped to `[0, integer_bound]` after each successor.
    * `:max_queue` — bounded network-buffer cap on pending messages (default
      10). When delivering a message would push the queue past this cap, the
      surplus outgoing messages are silently dropped — modelling a lossy
      network at the edge. Increase the cap for stronger guarantees.
  """
  def successors(%ProductState{} = ps, instance_irs, %IR.SystemIR{} = system_ir, opts \\ []) do
    relevance = Keyword.get(opts, :relevance)
    integer_bound = Keyword.get(opts, :integer_bound, 3)
    max_queue = Keyword.get(opts, :max_queue, 10)

    fire_timers = Keyword.get(opts, :fire_timers, true)

    delivered = pending_message_deliveries(ps, instance_irs, system_ir, max_queue)
    external = external_message_events(ps, instance_irs, system_ir, max_queue)
    timers = if fire_timers, do: timer_events(ps, instance_irs, system_ir, max_queue), else: []

    raw = delivered ++ external ++ timers

    successors =
      raw
      |> Enum.map(&post_process(&1, relevance, integer_bound))
      |> Enum.reject(&ProductState.same_as_parent?(&1, ps))
      |> Enum.uniq_by(&ProductState.fingerprint/1)

    if Keyword.get(opts, :coverage, false) do
      # A handler counts as *fired* if it was entered from this state, even if
      # its effect produced a state identical to the parent (emit-only / noop
      # handlers) that the successor list drops. So collect from `raw`, before
      # the same-as-parent / dedup filtering.
      fired =
        raw
        |> Enum.map(& &1.last_handler)
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()

      {successors, fired}
    else
      successors
    end
  end

  # Apply integer saturation + abstraction to a freshly computed successor.
  # When no `relevance` is supplied (Phase-1 callers) the successor is
  # returned unchanged.
  defp post_process(%ProductState{} = ps, nil, _bound), do: ps

  defp post_process(%ProductState{agents: agents} = ps, relevance, bound) do
    new_agents =
      Enum.into(agents, %{}, fn {name, state} ->
        case Map.get(relevance, name) do
          nil ->
            {name, state}

          %{tracked_int: tracked_int} = inst_relevance ->
            saturated = ProductState.saturate_integers(state, tracked_int, bound)
            abstracted = ProductState.abstract_agent_state(saturated, inst_relevance)
            {name, abstracted}
        end
      end)

    %ProductState{ps | agents: new_agents}
  end

  # ----------------------------------------------------------------------
  # Pending message delivery
  # ----------------------------------------------------------------------

  defp pending_message_deliveries(%ProductState{pending_messages: pending} = ps, instance_irs, system_ir, max_queue) do
    pending
    |> Enum.with_index()
    |> Enum.flat_map(fn {{from, to, msg}, idx} ->
      remaining = List.delete_at(pending, idx)
      dispatch(ps, to, msg, remaining, instance_irs, system_ir, {:deliver, from, to, msg}, max_queue)
    end)
  end

  # ----------------------------------------------------------------------
  # External event injection
  # ----------------------------------------------------------------------

  defp external_message_events(%ProductState{} = ps, instance_irs, system_ir, max_queue) do
    Enum.flat_map(system_ir.agents, fn instance ->
      ir = Map.get(instance_irs, instance.name)
      accepts = accepts_messages(ir)

      Enum.flat_map(accepts, fn message_spec ->
        msg = build_representative_message(message_spec)
        dispatch(ps, instance.name, msg, ps.pending_messages, instance_irs, system_ir,
          {:external, instance.name, msg}, max_queue)
      end)
    end)
  end

  # ----------------------------------------------------------------------
  # Timer / timeout / resilience events (Phase 3a)
  #
  # The standard model-checking treatment of a timer is a nondeterministic,
  # always-enabled action: the checker explores both "it fired" and "it hasn't
  # yet". Two kinds:
  #
  #   1. Internal-trigger handlers — any `on {...}` whose tag is NOT an `accepts`
  #      message is fired by a timer/timeout/resilience event, never by the
  #      protocol (monitored-liveness timeouts and bare timer atoms like
  #      `on :timer_recovery_fired` both lower to such handlers). We inject the
  #      trigger message; the handler's own guard gates it.
  #   2. Periodic `every` timers — carry their body actions directly (not as
  #      handlers); we run the body via the simulator.
  #
  # A firing that produces no state change is dropped by the same-as-parent /
  # fingerprint dedup in `successors/4`, so a self-looping timer cannot diverge.
  # ----------------------------------------------------------------------

  defp timer_events(%ProductState{} = ps, instance_irs, system_ir, max_queue) do
    Enum.flat_map(system_ir.agents, fn instance ->
      case Map.get(instance_irs, instance.name) do
        %IR.Agent{} = ir ->
          handler_timer_events(ps, instance.name, ir, instance_irs, system_ir, max_queue) ++
            periodic_timer_events(ps, instance.name, ir, system_ir, max_queue)

        _ ->
          []
      end
    end)
  end

  defp handler_timer_events(%ProductState{} = ps, name, ir, instance_irs, system_ir, max_queue) do
    accept_tags = ir |> accepts_messages() |> Enum.map(& &1.tag) |> MapSet.new()

    (ir.handlers || [])
    |> Enum.map(& &1.pattern.tag)
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(accept_tags, &1))
    |> Enum.flat_map(fn tag ->
      msg = {tag, %{}}
      dispatch(ps, name, msg, ps.pending_messages, instance_irs, system_ir,
        {:timer, name, tag}, max_queue)
    end)
  end

  defp periodic_timer_events(%ProductState{} = ps, name, %IR.Agent{periodic_timers: timers} = ir, system_ir, max_queue) do
    agent_state = Map.get(ps.agents, name, %{})
    connections = connections_from(system_ir, name)

    Enum.flat_map(timers || [], fn %IR.PeriodicTimer{tag: tag, actions: actions} ->
      synth = %IR.Handler{pattern: %IR.MatchPattern{tag: tag, bindings: []}, guard: nil, actions: actions}

      synth
      |> Simulator.simulate(agent_state, {tag, %{}}, name, connections)
      |> Enum.map(fn {new_state, outgoing} ->
        queued = ps.pending_messages ++ outgoing

        %ProductState{
          agents: Map.put(ps.agents, name, new_state),
          pending_messages: cap_queue(queued, max_queue),
          queue_truncated: truncated?(queued, max_queue),
          depth: ps.depth + 1,
          last_action: {:timer, name, tag},
          last_handler: {ir.name, {:every, tag}}
        }
      end)
    end)
  end

  defp accepts_messages(nil), do: []
  defp accepts_messages(%IR.Agent{protocol: nil}), do: []
  defp accepts_messages(%IR.Agent{protocol: %IR.Protocol{accepts: accepts}}), do: accepts || []

  defp build_representative_message(%IR.MessageType{tag: tag, fields: fields}) do
    tag_atom = if is_atom(tag), do: tag, else: String.to_atom(tag)
    field_map = Enum.into(fields || [], %{}, fn {name, type} ->
      name_atom = if is_atom(name), do: name, else: String.to_atom(name)
      {name_atom, default_for_type(type)}
    end)
    {tag_atom, field_map}
  end

  defp build_representative_message({tag, fields}) do
    tag_atom = if is_atom(tag), do: tag, else: String.to_atom(tag)
    field_map = Enum.into(fields || [], %{}, fn {name, type} ->
      name_atom = if is_atom(name), do: name, else: String.to_atom(name)
      {name_atom, default_for_type(type)}
    end)
    {tag_atom, field_map}
  end

  # A message recipient must be a bare atom to match the `instance_irs` keys.
  # Directed sends whose target came from an unlowered atom literal arrive as
  # `{:atom, "node1"}`; normalize so the reply is not silently dropped.
  defp normalize_recipient({:atom, a}) when is_binary(a), do: String.to_atom(a)
  defp normalize_recipient(other), do: other

  defp default_for_type(:integer), do: 0
  defp default_for_type(:atom), do: :representative
  defp default_for_type(:binary), do: ""
  defp default_for_type(:list), do: []
  defp default_for_type(:map), do: %{}
  defp default_for_type(_), do: nil

  # ----------------------------------------------------------------------
  # Dispatch one message to an agent and turn the simulator output into
  # successor product states.
  # ----------------------------------------------------------------------

  defp dispatch(%ProductState{} = ps, to_name, msg, remaining_pending, instance_irs, system_ir, action, max_queue) do
    to_name = normalize_recipient(to_name)

    case Map.get(instance_irs, to_name) do
      nil ->
        []

      ir ->
        agent_state = Map.get(ps.agents, to_name, %{})
        connections = connections_from(system_ir, to_name)

        case pick_handler(ir, msg, agent_state) do
          nil ->
            # No matching handler — catch-all semantics, no state change.
            []

          {index, handler} ->
            handler_id = {ir.name, index}

            handler
            |> Simulator.simulate(agent_state, msg, to_name, connections)
            |> Enum.map(fn {new_state, outgoing} ->
              queued = remaining_pending ++ outgoing

              %ProductState{
                agents: Map.put(ps.agents, to_name, new_state),
                pending_messages: cap_queue(queued, max_queue),
                queue_truncated: truncated?(queued, max_queue),
                depth: ps.depth + 1,
                last_action: action,
                last_handler: handler_id
              }
            end)
        end
    end
  end

  # Bounded network buffer: drop the surplus from the tail of the queue.
  # This is a deliberately lossy model — increasing `max_queue` recovers
  # stronger guarantees at the cost of state-space growth.
  defp cap_queue(queue, max_queue) when is_integer(max_queue) and max_queue >= 0 do
    Enum.take(queue, max_queue)
  end

  defp cap_queue(queue, _), do: queue

  # True when the queue overflowed and `cap_queue` dropped tail messages — the
  # order-sensitive truncation POR must treat as a dependency.
  defp truncated?(queued, max_queue) when is_integer(max_queue),
    do: length(queued) > max_queue

  defp truncated?(_queued, _max_queue), do: false

  # Returns `{index, handler}` for the first tag-matching handler whose guard is
  # satisfied (the index is its position in the agent's declared handler list,
  # used as a stable coverage id), or nil when none matches.
  defp pick_handler(%IR.Agent{handlers: handlers}, {tag, fields}, agent_state) do
    handlers
    |> Enum.with_index()
    |> Enum.find_value(nil, fn {h, index} ->
      if handler_tag_matches?(h, tag) and Simulator.guard_matches?(h, agent_state, fields) do
        {index, h}
      end
    end)
  end

  defp handler_tag_matches?(%IR.Handler{pattern: %IR.MatchPattern{tag: ptag}}, msg_tag) do
    cond do
      ptag == msg_tag -> true
      is_atom(ptag) and is_binary(msg_tag) -> Atom.to_string(ptag) == msg_tag
      is_binary(ptag) and is_atom(msg_tag) -> ptag == Atom.to_string(msg_tag)
      true -> false
    end
  end

  defp connections_from(%IR.SystemIR{connections: connections}, agent_name) do
    Enum.flat_map(connections || [], fn
      %{from: ^agent_name, to: to} -> [to]
      _ -> []
    end)
  end
end
