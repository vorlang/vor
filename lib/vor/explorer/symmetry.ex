defmodule Vor.Explorer.Symmetry do
  @moduledoc """
  Symmetry reduction for homogeneous, fully-symmetric agent systems.

  When all agents in a system block share the same type and have identical
  connection patterns, agent identities are interchangeable: a product
  state with `n1=:leader, n2=:follower, n3=:follower` is equivalent to
  every permutation of agent → state assignment. The explorer can collapse
  the entire equivalence class to a single canonical representative,
  reducing the visited set by up to N! for N identical agents.

  Symmetry is automatically detected when:

    1. Every system instance shares the same agent type, AND
    2. Every instance has the same `(outbound, inbound)` connection counts
       (covers fully-connected meshes and other symmetric topologies), AND
    3. No supplied invariant references a specific agent by name (any
       `{:named_agent_field, _, _}` term in any invariant body disables
       symmetry — named refs make agent identity load-bearing).

  Detection happens once per `verify_system/4` run; the BFS uses
  `canonical_fingerprint/2` for visited-set deduplication when symmetry is
  enabled and the regular `Vor.Explorer.ProductState.fingerprint/1`
  otherwise.
  """

  alias Vor.Explorer.ProductState
  alias Vor.IR

  @doc """
  True iff the supplied system block satisfies conditions 1 and 2 above.
  Condition 3 (no named-agent invariants) is checked separately via
  `invariant_disables_symmetry?/1` so the explorer can apply it across all
  invariants regardless of order.
  """
  def can_reduce?(%IR.SystemIR{agents: agents, connections: connections}) do
    types = Enum.map(agents, fn instance -> instance.type_name end)
    all_same_type? = length(Enum.uniq(types)) == 1

    connection_signatures =
      Enum.map(agents, fn %{name: name} ->
        outbound =
          Enum.count(connections || [], fn
            %{from: ^name} -> true
            _ -> false
          end)

        inbound =
          Enum.count(connections || [], fn
            %{to: ^name} -> true
            _ -> false
          end)

        {outbound, inbound}
      end)

    symmetric_topology? = length(Enum.uniq(connection_signatures)) <= 1

    all_same_type? and symmetric_topology?
  end

  def can_reduce?(_), do: false

  @doc """
  True if any invariant references a specific named agent. Such invariants
  break symmetry — the explorer must keep agent identities distinct so the
  named ref can be evaluated.
  """
  def invariant_disables_symmetry?(%IR.SystemInvariant{body: body}),
    do: uses_named_refs?(body)

  def invariant_disables_symmetry?(invariants) when is_list(invariants),
    do: Enum.any?(invariants, &invariant_disables_symmetry?/1)

  def invariant_disables_symmetry?(_), do: false

  defp uses_named_refs?({:named_agent_field, _, _}), do: true
  defp uses_named_refs?({:never, inner}), do: uses_named_refs?(inner)
  defp uses_named_refs?({:and, l, r}), do: uses_named_refs?(l) or uses_named_refs?(r)
  defp uses_named_refs?({:or, l, r}), do: uses_named_refs?(l) or uses_named_refs?(r)
  defp uses_named_refs?({op, l, r}) when op in [:==, :!=],
    do: uses_named_refs?(l) or uses_named_refs?(r)
  defp uses_named_refs?({:exists_pair, _, _, body}), do: uses_named_refs?(body)
  defp uses_named_refs?({:exists_single, _, body}), do: uses_named_refs?(body)
  defp uses_named_refs?({:for_all, body}), do: uses_named_refs?(body)
  defp uses_named_refs?(_), do: false

  @doc """
  Top-level decision: should symmetry reduction be applied for this run?
  Combines structural detection with the invariant check.
  """
  def enabled?(%IR.SystemIR{} = system_ir, invariants, opt) when is_list(invariants) do
    case opt do
      false -> false
      _ ->
        can_reduce?(system_ir) and not invariant_disables_symmetry?(invariants)
    end
  end

  @doc """
  Canonical fingerprint for an abstracted product state under symmetry.
  Each agent state is sorted into a deterministic key/value list, the list
  of per-agent states is itself sorted (interchangeable agents collapse to
  the same multiset), and pending messages are normalised by stripping the
  sender/receiver identity (only the message tag + field map remains).
  """
  def canonical_fingerprint(%ProductState{agents: agents, pending_messages: pending}) do
    agent_states =
      agents
      |> Map.values()
      |> Enum.map(&canonical_agent/1)
      |> Enum.sort()

    canonical_messages =
      pending
      |> Enum.map(fn {_from, _to, msg} -> msg end)
      |> Enum.sort()

    {agent_states, canonical_messages}
  end

  defp canonical_agent(state) when is_map(state) do
    state
    |> Enum.sort_by(fn {k, _} -> k end)
  end

  defp canonical_agent(other), do: other

  @doc """
  Number of identical agents that share the canonical type/connection
  signature. Used for the mix-task output's `N× reduction` line.
  """
  def reduction_factor(%IR.SystemIR{agents: agents}) do
    n = length(agents || [])
    factorial(n)
  end

  def reduction_factor(_), do: 1

  defp factorial(0), do: 1
  defp factorial(1), do: 1
  defp factorial(n) when n > 1, do: n * factorial(n - 1)
end
