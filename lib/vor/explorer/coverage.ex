defmodule Vor.Explorer.Coverage do
  @moduledoc """
  Declared-vs-reached coverage for a completed exploration.

  The language already knows what was *declared* — the enum values a `state`
  field can take, every `on {...}` handler, every `resilience` / `monitored`
  handler, every periodic `every` timer. After exploration we compare that
  surface against what was actually *reached* / *fired* and report the gap.

  A circuit breaker declaring three phases but exploring two, or a Raft node
  declaring three roles but only ever a follower, is its own warning — this
  module makes the checker say so.

  Coverage is aggregated per agent **type** (all instances of `RaftNode` share
  one declaration), unioning reached values across that type's instances.
  """

  alias Vor.IR

  @type t :: %{
          unreached_states: [map()],
          unfired_handlers: [map()],
          unfired_resilience: [map()],
          unfired_timers: [map()]
        }

  @doc """
  Compute the coverage report from the explorer's stats.

  `stats.state_map` supplies the reached states; `stats.fired_handlers` the set
  of `{agent_type, handler_index}` ids entered during exploration.
  """
  @spec analyze(IR.SystemIR.t(), map(), map()) :: t()
  def analyze(%IR.SystemIR{} = system_ir, instance_irs, stats) do
    states = Map.values(Map.get(stats, :state_map, %{}))
    fired = Map.get(stats, :fired_handlers, MapSet.new())
    types = types_with_instances(system_ir, instance_irs)

    %{
      unreached_states: unreached_states(types, states),
      unfired_handlers: unfired_handlers(types, fired),
      unfired_resilience: unfired_resilience(types, fired),
      unfired_timers: unfired_timers(types, fired)
    }
  end

  # %{agent_type => {ir, [instance_name, ...]}}
  defp types_with_instances(%IR.SystemIR{agents: instances}, instance_irs) do
    Enum.reduce(instances, %{}, fn inst, acc ->
      case Map.get(instance_irs, inst.name) do
        %IR.Agent{name: type} = ir ->
          Map.update(acc, type, {ir, [inst.name]}, fn {ir0, names} -> {ir0, [inst.name | names]} end)

        _ ->
          acc
      end
    end)
  end

  # ----------------------------------------------------------------------
  # 1.1a — unreached enum state values
  # ----------------------------------------------------------------------

  defp unreached_states(types, states) do
    for {type, {ir, instance_names}} <- types,
        %IR.StateField{name: field, values: values} <- ir.state_fields || [],
        is_list(values) and length(values) > 1,
        result = unreached_field(type, field, normalize_values(values), instance_names, states),
        result != nil do
      result
    end
  end

  defp unreached_field(type, field, declared, instance_names, states) do
    reached =
      for ps <- states, name <- instance_names, reduce: MapSet.new() do
        acc ->
          case ps.agents |> Map.get(name, %{}) |> Map.get(field) do
            nil -> acc
            v -> MapSet.put(acc, v)
          end
      end

    cond do
      # Field was abstracted away (cone-of-influence dropped it) — its concrete
      # values are unknown, so unreached detection would be a false positive.
      MapSet.member?(reached, :abstracted) ->
        nil

      true ->
        unreached = Enum.reject(declared, &MapSet.member?(reached, &1))

        if unreached == [] do
          nil
        else
          %{
            agent_type: type,
            field: field,
            declared: declared,
            reached: MapSet.to_list(reached) |> Enum.sort(),
            unreached: unreached
          }
        end
    end
  end

  defp normalize_values(values) do
    Enum.map(values, fn
      {:atom, s} when is_binary(s) -> String.to_atom(s)
      v -> v
    end)
  end

  # ----------------------------------------------------------------------
  # 1.1b — unfired handlers
  # ----------------------------------------------------------------------

  defp unfired_handlers(types, fired) do
    for {type, {ir, _names}} <- types,
        {handler, index} <- Enum.with_index(ir.handlers || []),
        not MapSet.member?(fired, {type, index}) do
      %{
        agent_type: type,
        index: index,
        label: handler_label(handler)
      }
    end
  end

  @doc """
  Reconstruct a concise `on {...} when <guard>` label for a handler.
  """
  def handler_label(%IR.Handler{pattern: %IR.MatchPattern{tag: tag}, guard: guard}) do
    base = "on {:#{tag}, ...}"

    case guard_str(guard) do
      nil -> base
      g -> base <> " when " <> g
    end
  end

  defp guard_str(nil), do: nil
  defp guard_str(%IR.GuardExpr{field: f, op: op, value: v}), do: "#{f} #{op_str(op)} #{val_str(v)}"

  defp guard_str(%IR.CompoundGuardExpr{op: op, left: l, right: r}) do
    "#{guard_str(l)} #{op} #{guard_str(r)}"
  end

  defp guard_str(_), do: nil

  defp val_str({:atom, s}) when is_binary(s), do: ":#{s}"
  defp val_str({:atom, a}) when is_atom(a), do: ":#{a}"
  defp val_str({:param, name}), do: "#{name}"
  defp val_str(v) when is_atom(v), do: ":#{v}"
  defp val_str(v) when is_integer(v), do: to_string(v)
  defp val_str(v), do: inspect(v)

  defp op_str(:==), do: "=="
  defp op_str(:!=), do: "!="
  defp op_str(op), do: to_string(op)

  # ----------------------------------------------------------------------
  # 1.1c — unfired resilience / timeout handlers (the timer gap announcing
  # itself). The explorer never fires these, so they are always reported.
  # ----------------------------------------------------------------------

  # A monitored-liveness timeout is fired through its synthesized handler (whose
  # tag is the monitor's `event_tag`). With timers firing (Phase 3a) it is only
  # reported when that handler was never actually entered.
  defp unfired_resilience(types, fired) do
    for {type, {ir, _names}} <- types,
        monitor <- ir.monitors || [],
        not monitor_fired?(ir, type, monitor, fired) do
      %{agent_type: type, kind: :monitored_liveness, name: monitor_name(monitor)}
    end
  end

  defp monitor_fired?(ir, type, monitor, fired) do
    event_tag = Map.get(monitor, :event_tag)

    (ir.handlers || [])
    |> Enum.with_index()
    |> Enum.any?(fn {h, idx} -> h.pattern.tag == event_tag and MapSet.member?(fired, {type, idx}) end)
  end

  defp unfired_timers(types, fired) do
    for {type, {ir, _names}} <- types,
        timer <- ir.periodic_timers || [],
        not MapSet.member?(fired, {type, {:every, Map.get(timer, :tag)}}) do
      %{agent_type: type, tag: Map.get(timer, :tag), interval: Map.get(timer, :interval)}
    end
  end

  defp monitor_name(%{name: name}), do: name
  defp monitor_name(monitor), do: Map.get(monitor, :name) || inspect(monitor)
end
