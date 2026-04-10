defmodule Vor.Simulator.InvariantChecker do
  @moduledoc """
  Checks system-level invariants against live BEAM process state.

  Queries each agent via `:sys.get_state/2` and evaluates invariants using
  the same `Vor.Explorer.Invariant` evaluator as the model checker. Dead
  agents are excluded from invariant evaluation — they have no state.
  """

  alias Vor.Explorer.{Invariant, ProductState}

  @doc """
  Query all agents and check every invariant. Returns `:ok` or
  `{:violation, name, agent_states}`.

  `agent_pids` is `%{name => pid}`. `agent_info` is `%{name => %{enum_field: atom | nil, ...}}`.
  """
  def check(agent_pids, agent_info, invariants) do
    agent_states =
      Enum.into(agent_pids, %{}, fn {name, pid} ->
        info = Map.get(agent_info, name, %{})
        {name, query_agent_state(pid, info)}
      end)

    live_states =
      agent_states
      |> Enum.reject(fn {_, state} -> state == :dead end)
      |> Enum.into(%{})

    ps = %ProductState{
      agents: live_states,
      pending_messages: [],
      depth: 0,
      last_action: :live_check
    }

    Enum.find_value(invariants, :ok, fn inv ->
      case Invariant.check(ps, inv) do
        :ok -> nil
        {:violation, name} -> {:violation, name, agent_states}
      end
    end)
  end

  @doc """
  Query a single agent's state via `:sys.get_state/2`. Returns a flat map
  with the enum state merged into the data map (using the declared enum
  field name), or `:dead` if the process is not alive or the call times out.
  """
  def query_agent_state(pid, agent_info \\ %{}) do
    if is_pid(pid) and Process.alive?(pid) do
      try do
        case :sys.get_state(pid, 2000) do
          # gen_statem: {state_atom, data_map}
          {state_atom, data} when is_atom(state_atom) and is_map(data) ->
            enum_field = Map.get(agent_info, :enum_field) || :phase
            Map.put(data, enum_field, state_atom)

          # gen_server: state map directly
          data when is_map(data) ->
            data

          other ->
            %{raw: other}
        end
      catch
        :exit, _ -> :dead
      end
    else
      :dead
    end
  end
end
