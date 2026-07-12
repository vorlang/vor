defmodule Vor.Explorer.Vacuity do
  @moduledoc """
  Invariant **relevance** analysis — the second axis of a guarantee, alongside
  strength (`proven` / `checked` / `monitored`).

  Strength answers *how strong is the evidence*. Relevance answers *did the
  verification engage with anything at all*. An invariant can pass at the
  strongest tier while constraining no reachable behavior — that is **vacuity**,
  and it is exactly what let the Raft example report "at most one leader,
  proven" over a state space in which no node was ever a leader.

  For each invariant we extract its **subject** (the atomic condition whose truth
  the property constrains) and check whether it was ever satisfiable in the
  explored state space (`Vor.Explorer.Invariant.subject_active?/2`):

    * **substantive** — the subject held in at least one explored state; the
      property was non-trivially checked.
    * **vacuous** — the subject was never true in any explored state; the
      invariant passed but constrained nothing reachable.
    * **unexercised** — a `monitored`-tier invariant whose subject never
      occurred (the monitored behavior was never reached; commonly because it
      sits behind a timer the explorer does not fire — see `KNOWN_ISSUES.md`).

  Subject-reachability is the cheap, high-value special case. The general answer
  is mutation-based formula vacuity (Beer et al.; Kupferman & Vardi); see
  `Vor.Explorer.Invariant.subject_active?/2` for where that would slot in.
  """

  alias Vor.Explorer.Invariant
  alias Vor.IR

  @type relevance :: :substantive | :vacuous | :unexercised

  @type verdict :: %{
          name: String.t(),
          tier: atom(),
          relevance: relevance(),
          subject: String.t(),
          subject_true_count: non_neg_integer(),
          total_states: non_neg_integer()
        }

  @doc """
  Analyze each safety invariant against the explored states, returning a
  relevance verdict per invariant.
  """
  @spec analyze([IR.SystemInvariant.t()], [struct()]) :: [verdict()]
  def analyze(invariants, states) when is_list(invariants) and is_list(states) do
    total = length(states)
    Enum.map(invariants, &analyze_one(&1, states, total))
  end

  defp analyze_one(%IR.SystemInvariant{name: name, tier: tier, body: body}, states, total) do
    subject_true = Enum.count(states, fn ps -> Invariant.subject_active?(ps, body) end)

    relevance =
      cond do
        subject_true > 0 -> :substantive
        tier == :monitored -> :unexercised
        true -> :vacuous
      end

    %{
      name: name,
      tier: tier,
      relevance: relevance,
      subject: describe_subject(body),
      subject_true_count: subject_true,
      total_states: total
    }
  end

  @doc """
  Human-readable rendering of an invariant's subject, e.g. `role == :leader`.
  """
  def describe_subject({:never, inner}), do: describe_subject(inner)
  def describe_subject({:for_all, inner}), do: "∀ agent: " <> describe_subject(inner)

  def describe_subject({tag, agents_where, _threshold})
      when tag in [:count_gt, :count_gte, :count_eq, :count_lt, :count_lte],
      do: describe_subject(agents_where)

  def describe_subject({:agents_where, field, op, value}),
    do: "#{field} #{op_str(op)} #{operand_str(value)}"

  def describe_subject({:exists_single, var, condition}),
    do: "∃ #{var}: " <> describe_subject(condition)

  def describe_subject({:exists_pair, va, vb, condition}),
    do: "∃ #{va},#{vb}: " <> describe_subject(condition)

  def describe_subject({op, left, right}) when op in [:==, :!=],
    do: "#{operand_str(left)} #{op_str(op)} #{operand_str(right)}"

  def describe_subject({op, left, right}) when op in [:and, :or],
    do: "(#{describe_subject(left)} #{op} #{describe_subject(right)})"

  def describe_subject(other), do: inspect(other)

  defp operand_str({:atom, a}) when is_binary(a), do: ":#{a}"
  defp operand_str({:atom, a}) when is_atom(a), do: ":#{a}"
  defp operand_str({:agent_field, var, field}), do: "#{var}.#{field}"
  defp operand_str({:named_agent_field, name, field}), do: "#{name}.#{field}"
  defp operand_str({:field, field}), do: "#{field}"
  defp operand_str(v) when is_atom(v), do: ":#{v}"
  defp operand_str(v) when is_binary(v), do: inspect(v)
  defp operand_str(v), do: to_string(v)

  defp op_str(:==), do: "=="
  defp op_str(:!=), do: "!="
  defp op_str(op), do: to_string(op)
end
