defmodule Vor.Simulator.MessageProxy do
  @moduledoc """
  A GenServer that wraps a real Vor agent and intercepts inter-agent
  messages. The proxy registers under the agent's name in the Registry;
  the real agent is started internally (anonymously). Other agents look up
  the proxy via Registry, so all inter-agent traffic flows through it.

  The proxy applies a configurable fault policy:

    * `:forward` — pass messages through immediately (default)
    * `:partition` — silently drop all messages (simulates network partition)
    * `:delay` — hold each message for a random duration from `delay_range`
    * `:drop` — randomly drop messages with probability `drop_probability`

  Internal messages (timers, state timeouts) go directly to the real agent
  because they use `self()` — the proxy never sees them.

  If the real agent crashes, the proxy restarts it internally (trap_exit).
  If the proxy itself is killed by the fault injector, the supervisor
  restarts both the proxy and a fresh real agent.
  """

  use GenServer

  # -------------------------------------------------------------------
  # Client API
  # -------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  def set_policy(proxy_pid, updates) when is_map(updates) do
    GenServer.call(proxy_pid, {:vor_set_policy, updates})
  end

  def get_real_pid(proxy_pid) do
    GenServer.call(proxy_pid, :vor_get_real_pid)
  end

  # -------------------------------------------------------------------
  # Callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    case start_real_agent(opts) do
      {:ok, real_pid} ->
        {:ok,
         %{
           real_pid: real_pid,
           agent_module: opts[:agent_module],
           agent_args: opts[:agent_args],
           behaviour: opts[:behaviour] || :gen_server,
           agent_name: opts[:agent_name],
           policy: :forward,
           delay_range: nil,
           drop_probability: 0.0
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:vor_set_policy, updates}, _from, state) do
    {:reply, :ok, Map.merge(state, updates)}
  end

  def handle_call(:vor_get_real_pid, _from, state) do
    {:reply, state.real_pid, state}
  end

  def handle_call(msg, _from, state) do
    case apply_fault(state) do
      :forward ->
        try_forward_call(msg, state)

      :drop ->
        {:reply, {:error, :partitioned}, state}

      {:delay, ms} ->
        Process.sleep(ms)
        try_forward_call(msg, state)
    end
  end

  @impl true
  def handle_cast(msg, state) do
    case apply_fault(state) do
      :forward ->
        forward_cast(msg, state)

      :drop ->
        :ok

      {:delay, ms} ->
        real = state.real_pid
        behaviour = state.behaviour

        spawn(fn ->
          Process.sleep(ms)
          do_cast(behaviour, real, msg)
        end)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %{real_pid: pid} = state) do
    case start_real_agent(%{
           agent_module: state.agent_module,
           agent_args: state.agent_args,
           behaviour: state.behaviour
         }) do
      {:ok, new_pid} ->
        {:noreply, %{state | real_pid: new_pid}}

      {:error, _} ->
        {:stop, reason, state}
    end
  end

  def handle_info(msg, state) do
    send(state.real_pid, msg)
    {:noreply, state}
  end

  # -------------------------------------------------------------------
  # Internal
  # -------------------------------------------------------------------

  defp start_real_agent(%{agent_module: mod, agent_args: args, behaviour: behaviour}) do
    case behaviour do
      :gen_statem ->
        :gen_statem.start_link(mod, args, [])

      _ ->
        GenServer.start_link(mod, args, [])
    end
  end

  defp try_forward_call(msg, state) do
    try do
      result = do_call(state.behaviour, state.real_pid, msg)
      {:reply, result, state}
    catch
      :exit, reason -> {:reply, {:error, reason}, state}
    end
  end

  defp forward_cast(msg, state) do
    do_cast(state.behaviour, state.real_pid, msg)
  end

  defp do_call(:gen_statem, pid, msg), do: :gen_statem.call(pid, msg, 5000)
  defp do_call(_, pid, msg), do: GenServer.call(pid, msg, 5000)

  defp do_cast(:gen_statem, pid, msg), do: :gen_statem.cast(pid, msg)
  defp do_cast(_, pid, msg), do: GenServer.cast(pid, msg)

  defp apply_fault(%{policy: :forward}), do: :forward
  defp apply_fault(%{policy: :partition}), do: :drop

  defp apply_fault(%{policy: :delay, delay_range: range}) when not is_nil(range) do
    {:delay, Enum.random(range)}
  end

  defp apply_fault(%{policy: :drop, drop_probability: prob}) when prob > 0 do
    if :rand.uniform() < prob, do: :drop, else: :forward
  end

  defp apply_fault(_), do: :forward
end
