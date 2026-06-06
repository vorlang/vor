defmodule Vor.Compat do
  @moduledoc """
  Protocol version compatibility checker.

  Compares two protocol versions (old and new) and determines whether a
  rolling deploy from old → new is safe. Compatible changes allow mixed
  versions to coexist; incompatible changes will break at runtime.

  Each protocol is a map with `:accepts` and `:emits` lists. Each entry
  has `:tag` (atom), `:fields` (list of `%{name, type, default}`), and
  optionally `:constraint`, `:max_queue`, `:priority`.
  """

  defstruct [:agent_name, :changes, :compatible]

  @doc """
  Compare old and new protocols. Returns `%Vor.Compat{changes, compatible}`.
  """
  def check(old_protocol, new_protocol) do
    old_accepts = normalize(old_protocol[:accepts] || old_protocol.accepts)
    new_accepts = normalize(new_protocol[:accepts] || new_protocol.accepts)
    old_emits = normalize(old_protocol[:emits] || old_protocol.emits)
    new_emits = normalize(new_protocol[:emits] || new_protocol.emits)

    accepts_changes = diff_message_types(old_accepts, new_accepts, :accepts)
    emits_changes = diff_message_types(old_emits, new_emits, :emits)

    all_changes = accepts_changes ++ emits_changes
    compatible = Enum.all?(all_changes, & &1.compatible)

    %__MODULE__{changes: all_changes, compatible: compatible}
  end

  defp normalize(list) when is_list(list) do
    Enum.map(list, fn
      %{tag: tag, fields: fields} = entry ->
        %{tag: to_atom(tag), fields: normalize_fields(fields),
          constraint: Map.get(entry, :constraint),
          max_queue: Map.get(entry, :max_queue),
          priority: Map.get(entry, :priority, false)}
      other -> other
    end)
  end

  defp normalize_fields(fields) when is_list(fields) do
    Enum.map(fields, fn
      %{name: name, type: type} = f ->
        %{name: to_atom(name), type: to_atom(type), default: Map.get(f, :default)}
      {name, type} ->
        %{name: to_atom(name), type: to_atom(type), default: nil}
    end)
  end

  defp normalize_fields(_), do: []

  defp to_atom(v) when is_atom(v), do: v
  defp to_atom(v) when is_binary(v), do: String.to_atom(v)

  defp diff_message_types(old_list, new_list, direction) do
    old_tags = MapSet.new(old_list, & &1.tag)
    new_tags = MapSet.new(new_list, & &1.tag)

    added = MapSet.difference(new_tags, old_tags)
    removed = MapSet.difference(old_tags, new_tags)
    common = MapSet.intersection(old_tags, new_tags)

    added_changes =
      Enum.map(added, fn tag ->
        case direction do
          :accepts ->
            %{type: :added_accepts, tag: tag, compatible: true,
              detail: "New message type — old agents won't send this"}
          :emits ->
            %{type: :added_emits, tag: tag, compatible: true,
              detail: "New response type — old receivers ignore unknown responses"}
        end
      end)

    removed_changes =
      Enum.map(removed, fn tag ->
        case direction do
          :accepts ->
            %{type: :removed_accepts, tag: tag, compatible: false,
              detail: "Removed message type — old agents may still send this"}
          :emits ->
            %{type: :removed_emits, tag: tag, compatible: false,
              detail: "Removed response — old receivers may depend on this"}
        end
      end)

    field_changes =
      Enum.flat_map(common, fn tag ->
        old = Enum.find(old_list, &(&1.tag == tag))
        new = Enum.find(new_list, &(&1.tag == tag))
        diff_fields(tag, old.fields, new.fields, direction)
      end)

    added_changes ++ removed_changes ++ field_changes
  end

  defp diff_fields(tag, old_fields, new_fields, direction) do
    old_names = MapSet.new(old_fields, & &1.name)
    new_names = MapSet.new(new_fields, & &1.name)

    added = MapSet.difference(new_names, old_names)
    removed = MapSet.difference(old_names, new_names)
    common = MapSet.intersection(old_names, new_names)

    added_changes =
      Enum.map(added, fn name ->
        field = Enum.find(new_fields, &(&1.name == name))
        has_default = field.default != nil

        case {direction, has_default} do
          {:accepts, true} ->
            %{type: :added_field, tag: tag, field: name, compatible: true,
              detail: "Added with default #{inspect(field.default)} — backward compatible"}
          {:accepts, false} ->
            %{type: :added_field, tag: tag, field: name, compatible: false,
              detail: "Added without default — old senders won't include this field"}
          {:emits, _} ->
            %{type: :added_field, tag: tag, field: name, compatible: true,
              detail: "Added to response — old receivers ignore unknown fields"}
        end
      end)

    removed_changes =
      Enum.map(removed, fn name ->
        case direction do
          :accepts ->
            %{type: :removed_field, tag: tag, field: name, compatible: true,
              detail: "Removed from accepts — old senders include it but new agent ignores"}
          :emits ->
            %{type: :removed_field, tag: tag, field: name, compatible: false,
              detail: "Removed from response — old receivers may depend on this field"}
        end
      end)

    type_changes =
      Enum.flat_map(common, fn name ->
        old_field = Enum.find(old_fields, &(&1.name == name))
        new_field = Enum.find(new_fields, &(&1.name == name))

        if old_field.type != new_field.type do
          compatible = type_widens?(old_field.type, new_field.type)
          [%{type: :changed_field_type, tag: tag, field: name, compatible: compatible,
            detail: "#{old_field.type} → #{new_field.type}" <>
              if(compatible, do: " (widened — safe)", else: " (narrowed — may break)")}]
        else
          []
        end
      end)

    added_changes ++ removed_changes ++ type_changes
  end

  defp type_widens?(old_type, new_type) do
    case {old_type, new_type} do
      {_, :term} -> true
      {:term, _} -> false
      {same, same} -> true
      _ -> false
    end
  end
end
