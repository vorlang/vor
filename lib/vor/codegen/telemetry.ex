defmodule Vor.Codegen.Telemetry do
  @moduledoc """
  Generates Erlang abstract format for `:telemetry.execute/3` calls.
  Used by the main codegen to insert telemetry at handler entry,
  transitions, emits, and init.
  """

  @doc "True iff telemetry generation is enabled (default true)."
  def enabled? do
    Application.get_env(:vor, :telemetry, true)
  end

  @doc """
  Generates abstract format for:

      telemetry:execute(EventName, Measurements, Metadata)

  `event_name` is a list of atoms, e.g. `[:vor, :transition]`.
  `metadata_pairs` is a list of `{atom, abstract_format_expr}` tuples.
  Returns a single expression (or an empty list if telemetry is disabled).
  """
  def call(event_name, metadata_pairs, l) do
    if enabled?() do
      [do_call(event_name, metadata_pairs, l)]
    else
      []
    end
  end

  defp do_call(event_name, metadata_pairs, l) do
    {:call, l,
     {:remote, l, {:atom, l, :telemetry}, {:atom, l, :execute}},
     [
       list_to_erl(Enum.map(event_name, &{:atom, l, &1}), l),
       {:map, l,
        [
          {:map_field_assoc, l, {:atom, l, :system_time},
           {:call, l, {:remote, l, {:atom, l, :erlang}, {:atom, l, :system_time}}, []}}
        ]},
       {:map, l,
        Enum.map(metadata_pairs, fn {key, val} ->
          {:map_field_assoc, l, {:atom, l, key}, val}
        end)}
     ]}
  end

  @doc "Read `__vor_agent_name__` from the data-map variable (or default to `undefined`)."
  def agent_name_expr(data_var, l) do
    {:call, l, {:remote, l, {:atom, l, :maps}, {:atom, l, :get}},
     [{:atom, l, :__vor_agent_name__}, {:var, l, data_var}, {:atom, l, :undefined}]}
  end

  defp list_to_erl([], l), do: {:nil, l}
  defp list_to_erl([h | t], l), do: {:cons, l, h, list_to_erl(t, l)}
end
