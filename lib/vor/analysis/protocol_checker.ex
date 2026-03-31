defmodule Vor.Analysis.ProtocolChecker do
  @moduledoc """
  Validates protocol conformance: emits match declared types,
  handler patterns match declared accepts, variables are scoped.
  """

  alias Vor.IR

  def check(%IR.Agent{} = agent) do
    errors =
      check_emit_types(agent) ++
      check_accept_coverage(agent) ++
      check_variable_scoping(agent)

    warnings = check_unhandled_accepts(agent)

    case errors do
      [] -> {:ok, warnings}
      errs -> {:error, errs}
    end
  end

  defp check_emit_types(%IR.Agent{protocol: proto, handlers: handlers}) do
    emit_tags = MapSet.new(proto.emits, & &1.tag)

    for handler <- handlers,
        %IR.Action{type: :emit, data: %IR.EmitAction{tag: tag}} <- handler.actions,
        not MapSet.member?(emit_tags, tag) do
      {:error, :emit_not_in_protocol, tag}
    end
  end

  defp check_accept_coverage(%IR.Agent{protocol: proto, handlers: handlers}) do
    accept_tags = MapSet.new(proto.accepts, & &1.tag)

    for handler <- handlers,
        not internal_event?(handler.pattern.tag),
        not MapSet.member?(accept_tags, handler.pattern.tag) do
      {:error, :handler_not_in_accepts, handler.pattern.tag}
    end
  end

  # Timer-fired events are internal to the agent, not protocol messages
  defp internal_event?(tag) do
    tag |> Atom.to_string() |> String.ends_with?("_fired")
  end

  defp check_variable_scoping(%IR.Agent{handlers: handlers}) do
    for handler <- handlers,
        error <- check_handler_scoping(handler) do
      error
    end
  end

  defp check_handler_scoping(%IR.Handler{pattern: pattern, actions: actions}) do
    # Variables bound from pattern matching
    pattern_vars =
      pattern.bindings
      |> Enum.filter(fn
        %IR.Binding{name: {:literal, _}} -> false
        _ -> true
      end)
      |> MapSet.new(& &1.name)

    # Variables bound by extern calls
    extern_vars =
      actions
      |> Enum.filter(fn
        %IR.Action{type: :extern_call, data: %{bind: bind}} when not is_nil(bind) -> true
        _ -> false
      end)
      |> MapSet.new(fn %IR.Action{data: %{bind: bind}} -> bind end)

    bound_vars = MapSet.union(pattern_vars, extern_vars)

    for %IR.Action{type: :emit, data: %IR.EmitAction{fields: fields}} <- actions,
        {_field, {:bound_var, var}} <- fields,
        not MapSet.member?(bound_vars, var) do
      {:error, :unbound_variable, var}
    end
  end

  defp check_unhandled_accepts(%IR.Agent{protocol: proto, handlers: handlers}) do
    handler_tags = MapSet.new(handlers, & &1.pattern.tag)

    for %IR.MessageType{tag: tag} <- proto.accepts,
        not MapSet.member?(handler_tags, tag) do
      {:warning, :unhandled_accept, tag}
    end
  end
end
