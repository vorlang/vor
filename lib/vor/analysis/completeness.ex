defmodule Vor.Analysis.Completeness do
  @moduledoc """
  Checks handler completeness:
  1. Emit path analysis — if a handler emits, every code path must emit
  2. Handler coverage — every `accepts` in the protocol must have a handler
  """

  alias Vor.IR

  @doc """
  Run all completeness checks on an agent IR.
  Returns `{:ok, warnings}` or `{:error, error_map}`.
  """
  def check(%IR.Agent{} = agent) do
    with :ok <- check_emit_paths(agent),
         :ok <- check_handler_coverage(agent) do
      {:ok, []}
    end
  end

  # --- Part 1: Emit path analysis ---

  defp check_emit_paths(%IR.Agent{handlers: handlers}) do
    errors =
      handlers
      |> Enum.flat_map(fn handler -> check_handler_emit_paths(handler) end)

    case errors do
      [] -> :ok
      [first | _] -> {:error, first}
    end
  end

  defp check_handler_emit_paths(%IR.Handler{actions: actions, pattern: pattern}) do
    # A handler is a "call handler" if it contains any emit anywhere in its action tree
    if has_any_emit?(actions) do
      case all_paths_emit?(actions) do
        true ->
          []

        false ->
          [%{
            type: :incomplete_handler,
            message: "Handler for #{inspect_pattern(pattern)} has a code path that doesn't produce a response",
            pattern: pattern.tag
          }]
      end
    else
      # Cast handler — no emits, else is optional
      []
    end
  end

  # Check if any emit exists anywhere in the action tree
  defp has_any_emit?(actions) do
    Enum.any?(actions, fn
      %IR.Action{type: :emit} -> true
      %IR.Action{type: :conditional, data: %IR.ConditionalAction{then_actions: ta, else_actions: ea}} ->
        has_any_emit?(ta) or has_any_emit?(ea)
      %IR.Action{type: :solve, data: %IR.SolveAction{body_actions: body}} ->
        has_any_emit?(body)
      _ -> false
    end)
  end

  # Check that every code path through the action list reaches an emit.
  # Returns true if we can guarantee every path emits.
  defp all_paths_emit?(actions) do
    # Walk actions sequentially. If we find a top-level emit, all paths from here emit.
    # If we find a conditional, both branches must emit (recursively).
    # If we reach the end without finding an emit, this path doesn't emit.
    Enum.any?(actions, fn action ->
      case action do
        %IR.Action{type: :emit} ->
          true

        %IR.Action{type: :conditional, data: %IR.ConditionalAction{then_actions: ta, else_actions: ea}} ->
          # Both branches must guarantee an emit
          all_paths_emit?(ta) and all_paths_emit?(ea)

        %IR.Action{type: :solve, data: %IR.SolveAction{body_actions: body}} ->
          all_paths_emit?(body)

        _ ->
          false
      end
    end)
  end

  # --- Part 2: Handler coverage ---

  defp check_handler_coverage(%IR.Agent{protocol: proto, handlers: handlers}) do
    handler_tags = MapSet.new(handlers, & &1.pattern.tag)

    missing =
      proto.accepts
      |> Enum.reject(fn %IR.MessageType{tag: tag} ->
        MapSet.member?(handler_tags, tag)
      end)

    case missing do
      [] ->
        :ok

      [first | _] ->
        {:error, %{
          type: :missing_handler,
          message: "Protocol declares: accepts #{inspect_msg_type(first)} but no handler matches it",
          tag: first.tag
        }}
    end
  end

  # --- Helpers ---

  defp inspect_pattern(%IR.MatchPattern{tag: tag}) do
    "{:#{tag}, ...}"
  end

  defp inspect_msg_type(%IR.MessageType{tag: tag, fields: fields}) do
    field_str = Enum.map_join(fields, ", ", fn {name, type} -> "#{name}: #{type}" end)
    "{:#{tag}, #{field_str}}"
  end
end
