defmodule Vor.Explorer.Relevance do
  @moduledoc """
  Computes which agent state fields are *relevant* to a system-level safety
  invariant. A field is relevant when:

    1. It is referenced directly in the invariant body, or
    2. It appears in a guard or conditional that gates a transition to an
       already-relevant field (transitive closure).

  Locally-bound variables inside handler bodies (`x = vote_count + 1`) are
  resolved back to their state-field sources so the closure can follow data
  flow through arithmetic and minmax expressions.

  Parameters are immutable after init. Once relevance is computed they are
  separated out: their values are still read by the simulator but they are
  not state-space dimensions.

  The result is a `%{instance_name => instance_relevance()}` map where each
  entry carries:

    * `:tracked_state` — state fields that must be tracked concretely.
    * `:tracked_int` — subset of `:tracked_state` whose declared type is
      `:integer`. Used to apply the integer saturation bound.
    * `:abstracted` — state fields that should be replaced with the symbolic
      `:abstracted` value (treated as `:unknown` by the simulator).
    * `:params` — names of parameters (always concrete, never fingerprinted).
  """

  alias Vor.IR

  @type field :: atom()
  @type instance_relevance :: %{
          tracked_state: MapSet.t(field),
          tracked_int: MapSet.t(field),
          abstracted: MapSet.t(field),
          params: MapSet.t(field)
        }

  @type t :: %{atom() => instance_relevance()}

  @doc """
  Compute per-instance relevance for the supplied invariants. The
  `instance_irs` map is keyed by instance name (e.g. `:n1`) — multiple
  instances of the same agent type share the same `IR.Agent` value, but the
  result is keyed per instance for downstream lookups.
  """
  def compute(%IR.SystemIR{} = system_ir, instance_irs, invariants) when is_map(instance_irs) and is_list(invariants) do
    invariant_field_set =
      invariants
      |> Enum.flat_map(&invariant_fields/1)
      |> MapSet.new()

    Enum.into(system_ir.agents, %{}, fn instance ->
      ir = Map.get(instance_irs, instance.name)
      {instance.name, compute_for_instance(ir, invariant_field_set)}
    end)
  end

  @doc """
  Extract the set of agent fields directly referenced in a system invariant
  body. Phase 2 supports the `count(agents where FIELD == :VALUE)` shapes —
  the field of interest is the first element of `agents_where`.
  """
  def invariant_fields(%IR.SystemInvariant{body: body}), do: invariant_fields(body)
  def invariant_fields({:never, condition}), do: invariant_fields(condition)

  # Phase 1 count(...) shapes.
  def invariant_fields({:count_gt, agents_where, _n}), do: invariant_fields(agents_where)
  def invariant_fields({:count_gte, agents_where, _n}), do: invariant_fields(agents_where)
  def invariant_fields({:count_eq, agents_where, _n}), do: invariant_fields(agents_where)
  def invariant_fields({:count_lt, agents_where, _n}), do: invariant_fields(agents_where)
  def invariant_fields({:count_lte, agents_where, _n}), do: invariant_fields(agents_where)
  def invariant_fields({:agents_where, field, _op, _value}), do: [field]

  # Phase 3 quantifier and named-ref shapes.
  def invariant_fields({:exists_pair, _va, _vb, condition}), do: invariant_fields(condition)
  def invariant_fields({:exists_single, _v, condition}), do: invariant_fields(condition)
  def invariant_fields({:for_all, condition}), do: invariant_fields(condition)
  def invariant_fields({:and, l, r}), do: invariant_fields(l) ++ invariant_fields(r)
  def invariant_fields({:or, l, r}), do: invariant_fields(l) ++ invariant_fields(r)

  def invariant_fields({op, left, right}) when op in [:==, :!=] do
    operand_fields(left) ++ operand_fields(right)
  end

  def invariant_fields(_), do: []

  defp operand_fields({:agent_field, _var, field}), do: [field]
  defp operand_fields({:named_agent_field, _name, field}), do: [field]
  defp operand_fields({:field, field}), do: [field]
  defp operand_fields(_), do: []

  # ----------------------------------------------------------------------
  # Per-instance computation
  # ----------------------------------------------------------------------

  defp compute_for_instance(nil, _invariant_fields) do
    %{
      tracked_state: MapSet.new(),
      tracked_int: MapSet.new(),
      abstracted: MapSet.new(),
      params: MapSet.new()
    }
  end

  defp compute_for_instance(%IR.Agent{} = ir, invariant_fields) do
    state_field_names = state_field_names(ir)
    data_field_types = Enum.into(ir.data_fields || [], %{}, fn f -> {f.name, f.type} end)
    param_names = MapSet.new(Enum.map(ir.params || [], fn {n, _t} -> n end))

    relevant = transitive_closure(invariant_fields, ir)

    # Restrict to fields that actually exist on this agent.
    all_state = MapSet.new(state_field_names)
    relevant_in_agent = MapSet.intersection(relevant, all_state)

    tracked_state = MapSet.difference(relevant_in_agent, param_names)
    abstracted = MapSet.difference(all_state, MapSet.union(tracked_state, param_names))

    tracked_int =
      tracked_state
      |> Enum.filter(fn name -> Map.get(data_field_types, name) == :integer end)
      |> MapSet.new()

    %{
      tracked_state: tracked_state,
      tracked_int: tracked_int,
      abstracted: abstracted,
      params: param_names
    }
  end

  defp state_field_names(%IR.Agent{} = ir) do
    enum_names =
      Enum.map(ir.state_fields || [], fn %IR.StateField{name: name} -> name end)

    data_names =
      Enum.map(ir.data_fields || [], fn %IR.DataField{name: name} -> name end)

    enum_names ++ data_names
  end

  # ----------------------------------------------------------------------
  # Transitive closure: keep expanding by following transitions whose target
  # is already relevant.
  # ----------------------------------------------------------------------

  defp transitive_closure(initial, %IR.Agent{} = ir) do
    do_close(initial, ir)
  end

  defp do_close(current, ir) do
    expanded =
      Enum.reduce(current, current, fn field, acc ->
        MapSet.union(acc, find_influencers(ir, field))
      end)

    if MapSet.equal?(expanded, current), do: current, else: do_close(expanded, ir)
  end

  defp find_influencers(%IR.Agent{handlers: handlers}, target_field) do
    handlers
    |> Enum.filter(&handler_transitions?(&1, target_field))
    |> Enum.flat_map(&fields_influencing_transition(&1, target_field))
    |> MapSet.new()
  end

  # Does any action in this handler transition `target_field`?
  defp handler_transitions?(%IR.Handler{actions: actions}, target_field) do
    actions_transition?(actions, target_field)
  end

  defp actions_transition?(actions, target_field) do
    Enum.any?(actions, fn
      nil -> false
      %IR.Action{type: :transition, data: %IR.TransitionAction{field: ^target_field}} -> true
      %IR.Action{type: :conditional, data: %IR.ConditionalAction{then_actions: ta, else_actions: ea}} ->
        actions_transition?(ta, target_field) or actions_transition?(ea, target_field)
      _ -> false
    end)
  end

  # Collect all fields that influence whether/what the transition to
  # `target_field` does inside this handler. This is the union of:
  #
  #   * guard fields,
  #   * fields read by the value expression of the transition itself,
  #   * fields referenced in conditions of any conditional whose then- or
  #     else-branch contains a transition to `target_field`.
  #
  # Local var bindings are followed back to their state-field sources via
  # the `local_sources` map built sequentially through the handler body.
  defp fields_influencing_transition(%IR.Handler{guard: guard, actions: actions}, target_field) do
    guard_fields = guard_field_refs(guard)
    {body_fields, _} = walk_for_target(actions, target_field, %{}, [])
    Enum.uniq(guard_fields ++ body_fields)
  end

  defp walk_for_target([], _target, locals, acc), do: {acc, locals}

  defp walk_for_target([action | rest], target, locals, acc) do
    {new_acc, new_locals} = step_for_target(action, target, locals, acc)
    walk_for_target(rest, target, new_locals, new_acc)
  end

  defp step_for_target(nil, _target, locals, acc), do: {acc, locals}

  defp step_for_target(
         %IR.Action{type: :var_binding, data: %IR.VarBindingAction{name: name, expr: expr}},
         _target,
         locals,
         acc
       ) do
    sources = expr_field_refs(expr, locals)
    {acc, Map.put(locals, name, sources)}
  end

  defp step_for_target(
         %IR.Action{type: :transition, data: %IR.TransitionAction{field: field, value: value}},
         target,
         locals,
         acc
       )
       when field == target do
    {acc ++ value_field_refs(value, locals), locals}
  end

  defp step_for_target(
         %IR.Action{type: :conditional, data: %IR.ConditionalAction{condition: cond_, then_actions: ta, else_actions: ea}},
         target,
         locals,
         acc
       ) do
    {then_fields, _} = walk_for_target(ta, target, locals, [])
    {else_fields, _} = walk_for_target(ea, target, locals, [])

    branch_touches_target? =
      actions_transition?(ta, target) or actions_transition?(ea, target)

    cond_fields =
      if branch_touches_target?, do: condition_field_refs(cond_, locals), else: []

    {acc ++ then_fields ++ else_fields ++ cond_fields, locals}
  end

  defp step_for_target(_, _target, locals, acc), do: {acc, locals}

  # ----------------------------------------------------------------------
  # Field-reference extraction
  # ----------------------------------------------------------------------

  defp guard_field_refs(nil), do: []

  defp guard_field_refs(%IR.GuardExpr{field: field, value: value}) do
    # The `field` slot is a name being compared, but it might be a pattern
    # variable rather than a state field. The `value` slot can be
    # `{:param, name}` (which the lowerer also uses for state fields), an
    # arithmetic expression, etc — anything that could reference state.
    [field | value_field_refs(value, %{})]
  end

  defp guard_field_refs(%IR.CompoundGuardExpr{left: l, right: r}),
    do: guard_field_refs(l) ++ guard_field_refs(r)

  defp guard_field_refs(_), do: []

  defp condition_field_refs(%IR.Condition{left: l, right: r}, locals),
    do: value_field_refs(l, locals) ++ value_field_refs(r, locals)

  defp condition_field_refs(%IR.CompoundCondition{left: l, right: r}, locals),
    do: condition_field_refs(l, locals) ++ condition_field_refs(r, locals)

  defp condition_field_refs(_, _locals), do: []

  # Walk a value expression collecting any state-field references. Locally
  # bound variables are expanded via the running `locals` map.
  defp value_field_refs({:param, name}, locals) do
    case Map.fetch(locals, name) do
      {:ok, sources} -> sources
      :error -> [name]
    end
  end

  defp value_field_refs({:bound_var, name}, locals) do
    case Map.fetch(locals, name) do
      {:ok, sources} -> sources
      :error -> []
    end
  end

  defp value_field_refs({:arith, _op, l, r}, locals),
    do: value_field_refs(l, locals) ++ value_field_refs(r, locals)

  defp value_field_refs({:minmax, _op, l, r}, locals),
    do: value_field_refs(l, locals) ++ value_field_refs(r, locals)

  defp value_field_refs({:map_op, _op, args}, locals),
    do: Enum.flat_map(args || [], &value_field_refs(&1, locals))

  defp value_field_refs({:list, items}, locals),
    do: Enum.flat_map(items || [], &value_field_refs(&1, locals))

  defp value_field_refs({:integer, _}, _), do: []
  defp value_field_refs({:atom, _}, _), do: []
  defp value_field_refs(_, _), do: []

  defp expr_field_refs(expr, locals), do: value_field_refs(expr, locals)
end
