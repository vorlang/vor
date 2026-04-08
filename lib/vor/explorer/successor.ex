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
  """
  def successors(%ProductState{} = ps, instance_irs, %IR.SystemIR{} = system_ir) do
    delivered = pending_message_deliveries(ps, instance_irs, system_ir)
    external = external_message_events(ps, instance_irs, system_ir)

    (delivered ++ external)
    |> Enum.reject(&ProductState.same_as_parent?(&1, ps))
    |> Enum.uniq_by(&ProductState.fingerprint/1)
  end

  # ----------------------------------------------------------------------
  # Pending message delivery
  # ----------------------------------------------------------------------

  defp pending_message_deliveries(%ProductState{pending_messages: pending} = ps, instance_irs, system_ir) do
    pending
    |> Enum.with_index()
    |> Enum.flat_map(fn {{from, to, msg}, idx} ->
      remaining = List.delete_at(pending, idx)
      dispatch(ps, to, msg, remaining, instance_irs, system_ir, {:deliver, from, to, msg})
    end)
  end

  # ----------------------------------------------------------------------
  # External event injection
  # ----------------------------------------------------------------------

  defp external_message_events(%ProductState{} = ps, instance_irs, system_ir) do
    Enum.flat_map(system_ir.agents, fn instance ->
      ir = Map.get(instance_irs, instance.name)
      accepts = accepts_messages(ir)

      Enum.flat_map(accepts, fn message_spec ->
        msg = build_representative_message(message_spec)
        dispatch(ps, instance.name, msg, ps.pending_messages, instance_irs, system_ir,
          {:external, instance.name, msg})
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

  defp dispatch(%ProductState{} = ps, to_name, msg, remaining_pending, instance_irs, system_ir, action) do
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

          handler ->
            handler
            |> Simulator.simulate(agent_state, msg, to_name, connections)
            |> Enum.map(fn {new_state, outgoing} ->
              %ProductState{
                agents: Map.put(ps.agents, to_name, new_state),
                pending_messages: remaining_pending ++ outgoing,
                depth: ps.depth + 1,
                last_action: action
              }
            end)
        end
    end
  end

  defp pick_handler(%IR.Agent{handlers: handlers}, {tag, fields}, agent_state) do
    matching = Enum.filter(handlers, fn h ->
      handler_tag_matches?(h, tag)
    end)

    Enum.find(matching, fn h -> Simulator.guard_matches?(h, agent_state, fields) end)
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
