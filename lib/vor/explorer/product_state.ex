defmodule Vor.Explorer.ProductState do
  @moduledoc """
  A snapshot of the entire system: every agent's tracked state plus any
  in-flight messages.

  Phase 1 keeps the representation simple — every state field of every agent
  is tracked verbatim. State abstraction (Phase 2) will collapse fields that
  don't influence guards or invariants.
  """

  alias Vor.IR

  defstruct agents: %{},
            pending_messages: [],
            depth: 0,
            last_action: :initial

  @type agent_state :: %{atom() => term()}
  @type pending_message :: {atom(), atom(), tuple()}

  @type t :: %__MODULE__{
          agents: %{atom() => agent_state()},
          pending_messages: [pending_message()],
          depth: non_neg_integer(),
          last_action: term()
        }

  @doc """
  Construct the initial product state from a system IR and a map of agent IRs
  keyed by their type name.
  """
  def initial(%IR.SystemIR{} = system_ir, instance_irs) when is_map(instance_irs) do
    agents =
      Enum.reduce(system_ir.agents, %{}, fn instance, acc ->
        # `instance_irs` is keyed by **instance name** (e.g. :node1) so a
        # single agent type with multiple instances still has one entry per
        # instance — they share the same IR object.
        agent_ir =
          Map.get(instance_irs, instance.name) ||
            Map.get(instance_irs, instance.type_name)

        Map.put(acc, instance.name, initial_agent_state(agent_ir, instance.params))
      end)

    %__MODULE__{
      agents: agents,
      pending_messages: [],
      depth: 0,
      last_action: :initial
    }
  end

  defp initial_agent_state(nil, params) do
    Enum.into(params || [], %{})
  end

  defp initial_agent_state(%IR.Agent{} = ir, params) do
    state = %{}

    # Enum state field — first declared value is the initial state
    state =
      case ir.state_fields do
        [%IR.StateField{name: field, initial: nil, values: [first | _]} | _] ->
          Map.put(state, field, first)

        [%IR.StateField{name: field, initial: init} | _] when not is_nil(init) ->
          Map.put(state, field, init)

        _ ->
          state
      end

    # Data fields — type defaults
    state =
      Enum.reduce(ir.data_fields || [], state, fn field, acc ->
        Map.put(acc, field.name, default_for_type(field.type))
      end)

    # Parameters override defaults
    Enum.reduce(params || [], state, fn {key, value}, acc ->
      Map.put(acc, key, value)
    end)
  end

  defp default_for_type(:integer), do: 0
  defp default_for_type(:atom), do: nil
  defp default_for_type(:map), do: %{}
  defp default_for_type(:list), do: []
  defp default_for_type(:binary), do: ""
  defp default_for_type(_), do: nil

  @doc """
  Canonical representation used for visited-set deduplication. Pending messages
  are sorted so that two states differing only in queue order are treated as
  equal — this matches the BEAM message-delivery model where ordering between
  distinct sender/receiver pairs is not guaranteed.
  """
  def fingerprint(%__MODULE__{agents: agents, pending_messages: pending}) do
    {agents, Enum.sort(pending)}
  end

  @doc """
  True when a successor's tracked state is identical to its parent. Used to
  drop no-op message deliveries before they are even hashed for the visited
  set.
  """
  def same_as_parent?(%__MODULE__{} = successor, %__MODULE__{} = parent) do
    fingerprint(successor) == fingerprint(parent)
  end
end
