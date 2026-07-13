defmodule Vor.Explorer.Invariant do
  @moduledoc """
  Evaluates system-level safety invariants against a product state.

  Phase 1 supports the restricted form:

      never(count(agents where FIELD == :VALUE) OP N)

  where OP is one of `>`, `>=`, `==`, `<`, `<=`. The internal representation
  uses one tag per operator (`:count_gt`, `:count_gte`, `:count_eq`,
  `:count_lt`, `:count_lte`) so the evaluator stays branch-free.
  """

  alias Vor.Explorer.ProductState
  alias Vor.IR

  @doc """
  Returns `:ok` if the invariant holds in `ps`, or `{:violation, name}` if it
  is violated.
  """
  def check(%ProductState{} = ps, %IR.SystemInvariant{name: name, body: body}) do
    if evaluate(ps, body) do
      :ok
    else
      {:violation, name}
    end
  end

  @doc """
  True if the invariant's *subject* — the atomic condition whose truth the
  property constrains — is active in `ps`. Used by vacuity detection
  (`Vor.Explorer.Vacuity`) to decide whether an invariant ever engaged with
  reachable behavior.

  The subject is deliberately *weaker* than the violation condition: for
  `never(count(agents where role == :leader) > 1)` the subject is "some agent
  has role == :leader", not "more than one does". An invariant whose subject is
  never true across the explored space did not constrain any reachable
  behavior — it is vacuously satisfied.

  NOTE: this is subject-reachability, the cheap high-value special case. The
  general answer is mutation-based formula vacuity (Beer et al.; Kupferman &
  Vardi — replace each subformula with true/false and re-check); that would slot
  in here as an alternative strategy.
  """
  def subject_active?(%ProductState{} = ps, {:never, condition}),
    do: subject_active?(ps, condition)

  # `for_all agents, COND` is a universal quantifier: its subject is the
  # quantification domain. Universal vacuity is an *empty* domain, which never
  # happens (a system always has agents), so a for-all constrains every reached
  # state and is substantive whenever any agent exists.
  def subject_active?(%ProductState{agents: agents}, {:for_all, _condition}),
    do: map_size(agents) > 0

  def subject_active?(%ProductState{} = ps, {tag, agents_where, _threshold})
      when tag in [:count_gt, :count_gte, :count_eq, :count_lt, :count_lte],
      do: count_matching(ps, agents_where) >= 1

  def subject_active?(%ProductState{} = ps, {:agents_where, _, _, _} = agents_where),
    do: count_matching(ps, agents_where) >= 1

  def subject_active?(%ProductState{agents: agents}, {:exists_single, var, condition}) do
    Enum.any?(agents, fn {_name, state} ->
      eval_with_bindings(condition, %{var => state})
    end)
  end

  # Subject reachability for a pairwise invariant `never(exists A, B where COND)`.
  # The property is substantive when the entity it constrains is reachable — not
  # only when the forbidden *pair* actually arises. We test COND with a single
  # agent bound to both variables: for the common "two agents in the same bad
  # state" shape (e.g. `A.role == :leader and B.role == :leader and
  # A.current_term == B.current_term`) this reduces to the per-agent core
  # (`role == :leader`), so a HOLDING pairwise invariant over a space where
  # leaders exist is correctly substantive rather than falsely vacuous.
  #
  # (Limitation: for a purely *relational* condition like `A.term != B.term`
  # self-pairing yields false; such divergence invariants are not covered by
  # this heuristic. See the general mutation-based approach noted above.)
  def subject_active?(%ProductState{agents: agents}, {:exists_pair, var_a, var_b, condition}) do
    Enum.any?(agents, fn {_name, state} ->
      eval_with_bindings(condition, %{var_a => state, var_b => state})
    end)
  end

  def subject_active?(%ProductState{} = ps, {op, _, _} = expr) when op in [:==, :!=, :and, :or],
    do: eval_with_bindings(expr, %{__product_state__: ps})

  def subject_active?(_ps, _other), do: false

  # `never(condition)` — invariant holds when the condition is false.
  defp evaluate(ps, {:never, condition}), do: not evaluate_condition(ps, condition)

  # `for_all agents, condition` — top-level positive form (no `never` wrapper)
  defp evaluate(ps, {:for_all, _} = expr), do: evaluate_condition(ps, expr)

  defp evaluate(ps, other), do: not evaluate_condition(ps, other)

  defp evaluate_condition(ps, {:count_gt, agents_where, threshold}),
    do: count_matching(ps, agents_where) > threshold

  defp evaluate_condition(ps, {:count_gte, agents_where, threshold}),
    do: count_matching(ps, agents_where) >= threshold

  defp evaluate_condition(ps, {:count_eq, agents_where, threshold}),
    do: count_matching(ps, agents_where) == threshold

  defp evaluate_condition(ps, {:count_lt, agents_where, threshold}),
    do: count_matching(ps, agents_where) < threshold

  defp evaluate_condition(ps, {:count_lte, agents_where, threshold}),
    do: count_matching(ps, agents_where) <= threshold

  # Phase 3: exists/for_all/named-agent forms.
  defp evaluate_condition(%ProductState{agents: agents}, {:exists_pair, var_a, var_b, condition}) do
    pairs =
      for {name_a, state_a} <- agents,
          {name_b, state_b} <- agents,
          name_a != name_b,
          do: %{var_a => state_a, var_b => state_b}

    Enum.any?(pairs, fn bindings -> eval_with_bindings(condition, bindings) end)
  end

  defp evaluate_condition(%ProductState{agents: agents}, {:exists_single, var, condition}) do
    Enum.any?(agents, fn {_name, state} ->
      eval_with_bindings(condition, %{var => state})
    end)
  end

  defp evaluate_condition(%ProductState{agents: agents}, {:for_all, condition}) do
    Enum.all?(agents, fn {_name, state} ->
      eval_with_bindings(condition, %{__field_state__: state})
    end)
  end

  # Single named-agent comparison or boolean combination thereof
  # (`never(n1.role == :leader)` becomes `{:never, {:==, {:named_agent_field, :n1, :role}, :leader}}`).
  defp evaluate_condition(ps, {op, _, _} = expr) when op in [:==, :!=, :and, :or] do
    eval_with_bindings(expr, %{__product_state__: ps})
  end

  defp evaluate_condition(_ps, _other), do: false

  defp count_matching(%ProductState{agents: agents}, {:agents_where, field, op, value}) do
    agents
    |> Map.values()
    |> Enum.count(fn agent_state ->
      compare(Map.get(agent_state, field), op, value)
    end)
  end

  # ----------------------------------------------------------------------
  # Boolean expression evaluator with quantifier bindings
  # ----------------------------------------------------------------------

  defp eval_with_bindings({:and, l, r}, bindings),
    do: eval_with_bindings(l, bindings) and eval_with_bindings(r, bindings)

  defp eval_with_bindings({:or, l, r}, bindings),
    do: eval_with_bindings(l, bindings) or eval_with_bindings(r, bindings)

  defp eval_with_bindings({op, left, right}, bindings) when op in [:==, :!=] do
    compare(resolve(left, bindings), op, resolve(right, bindings))
  end

  defp eval_with_bindings(_, _bindings), do: false

  # Resolve a comparison operand against the active bindings.
  defp resolve({:agent_field, var, field}, bindings) do
    case Map.get(bindings, var) do
      nil -> nil
      state when is_map(state) -> Map.get(state, field)
      _ -> nil
    end
  end

  defp resolve({:field, field}, %{__field_state__: state}) when is_map(state),
    do: Map.get(state, field)

  defp resolve({:named_agent_field, name, field}, %{__product_state__: %ProductState{agents: agents}}) do
    case Map.get(agents, name) do
      nil -> nil
      state -> Map.get(state, field)
    end
  end

  # Bare value comparisons (atoms, integers, etc) — used as RHS literals.
  defp resolve(value, _bindings) when is_atom(value) or is_integer(value) or is_binary(value),
    do: value

  defp resolve(_, _bindings), do: nil

  defp compare(actual, :==, expected), do: actual == expected
  defp compare(actual, :!=, expected), do: actual != expected
end
