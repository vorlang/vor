defmodule Vor.Verification.Protocol do
  @moduledoc """
  Protocol composition checker for multi-agent systems.
  Verifies that connected agents have compatible protocols.
  """

  alias Vor.IR

  @doc """
  Check protocol composition for a system.
  Returns `{:ok, warnings}` or `{:error, errors}`.
  """
  def check(%IR.SystemIR{} = system, agent_irs) do
    agent_map = Map.new(agent_irs, fn {name, ir} -> {name, ir} end)
    errors = []
    warnings = []

    # Check each connection
    {conn_errors, conn_warnings} = check_connections(system.connections, system.agents, agent_map)
    errors = errors ++ conn_errors
    warnings = warnings ++ conn_warnings

    # Check send statements reference valid targets
    send_errors = check_send_targets(system, agent_map)
    errors = errors ++ send_errors

    # Check for dead accepts
    dead_warnings = check_dead_accepts(system, agent_map)
    warnings = warnings ++ dead_warnings

    case errors do
      [] -> {:ok, warnings}
      _ -> {:error, errors}
    end
  end

  defp check_connections(connections, _agents, agent_map) do
    Enum.reduce(connections, {[], []}, fn %{from: from_name, to: to_name}, {errs, warns} ->
      from_ir = Map.get(agent_map, from_name)
      to_ir = Map.get(agent_map, to_name)

      cond do
        is_nil(from_ir) ->
          {[%{type: :unknown_agent, agent: from_name} | errs], warns}

        is_nil(to_ir) ->
          {[%{type: :unknown_agent, agent: to_name} | errs], warns}

        true ->
          sends = from_ir.protocol.sends || []
          accepts = to_ir.protocol.accepts || []
          {new_errs, new_warns} = check_message_compatibility(sends, accepts, from_name, to_name)
          {errs ++ new_errs, warns ++ new_warns}
      end
    end)
  end

  defp check_message_compatibility(sends, accepts, from_name, to_name) do
    accept_map = Map.new(accepts, fn %IR.MessageType{tag: tag} = mt -> {tag, mt} end)

    Enum.reduce(sends, {[], []}, fn %IR.MessageType{tag: tag, fields: fields} = _send_type, {errs, warns} ->
      case Map.get(accept_map, tag) do
        nil ->
          err = %{type: :protocol_mismatch, from: from_name, to: to_name,
                  detail: "#{from_name} sends {:#{tag}, ...} but #{to_name} does not accept it"}
          {[err | errs], warns}

        %IR.MessageType{fields: accept_fields} ->
          send_field_names = Enum.map(fields, fn {name, _} -> name end)
          accept_field_names = Enum.map(accept_fields, fn {name, _} -> name end)

          if send_field_names == accept_field_names do
            {errs, warns}
          else
            err = %{type: :protocol_mismatch, from: from_name, to: to_name,
                    detail: "field name mismatch on {:#{tag}, ...}: #{inspect(send_field_names)} vs #{inspect(accept_field_names)}"}
            {[err | errs], warns}
          end
      end
    end)
  end

  defp check_send_targets(%IR.SystemIR{} = system, agent_map) do
    agent_names = MapSet.new(system.agents, fn a -> a.name end)
    connection_map = MapSet.new(system.connections, fn %{from: f, to: t} -> {f, t} end)

    Enum.flat_map(system.agents, fn agent_inst ->
      ir = Map.get(agent_map, agent_inst.name)
      if ir do
        check_agent_sends(ir.handlers, agent_inst.name, agent_names, connection_map)
      else
        []
      end
    end)
  end

  defp check_agent_sends(handlers, agent_name, agent_names, connection_map) do
    Enum.flat_map(handlers, fn handler ->
      Enum.flat_map(handler.actions, fn action ->
        check_action_sends(action, agent_name, agent_names, connection_map)
      end)
    end)
  end

  defp check_action_sends(%IR.Action{type: :send, data: %IR.SendAction{target: target}}, agent_name, agent_names, connection_map) do
    cond do
      not MapSet.member?(agent_names, target) ->
        [%{type: :unknown_agent, agent: target, in: agent_name}]

      not MapSet.member?(connection_map, {agent_name, target}) ->
        [%{type: :send_not_connected, from: agent_name, to: target}]

      true ->
        []
    end
  end

  defp check_action_sends(%IR.Action{type: :conditional, data: %{then_actions: ta, else_actions: ea}}, agent_name, agent_names, connection_map) do
    Enum.flat_map(ta, &check_action_sends(&1, agent_name, agent_names, connection_map)) ++
    Enum.flat_map(ea, &check_action_sends(&1, agent_name, agent_names, connection_map))
  end

  defp check_action_sends(_, _, _, _), do: []

  defp check_dead_accepts(%IR.SystemIR{} = system, agent_map) do
    # Build a set of all message tags that any connected sender provides
    sent_tags_per_receiver = Enum.reduce(system.connections, %{}, fn %{from: from, to: to}, acc ->
      from_ir = Map.get(agent_map, from)
      sends = if from_ir, do: Enum.map(from_ir.protocol.sends || [], & &1.tag), else: []
      Map.update(acc, to, MapSet.new(sends), fn existing -> MapSet.union(existing, MapSet.new(sends)) end)
    end)

    Enum.flat_map(system.agents, fn agent_inst ->
      ir = Map.get(agent_map, agent_inst.name)
      if ir do
        available = Map.get(sent_tags_per_receiver, agent_inst.name, MapSet.new())
        Enum.flat_map(ir.protocol.accepts, fn %IR.MessageType{tag: tag} ->
          if MapSet.member?(available, tag) do
            []
          else
            ["Agent #{agent_inst.name} accepts {:#{tag}, ...} but no connected agent sends it"]
          end
        end)
      else
        []
      end
    end)
  end
end
