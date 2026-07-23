defmodule Vor.Simulator.SupervisorBuilder do
  @moduledoc """
  Builds a simulation supervisor tree that wraps each agent in a
  `Vor.Simulator.MessageProxy`. The proxy registers under the agent's
  name in the Registry; the real agent is started internally by the proxy.

  This replaces the system module's compiled supervisor during simulation,
  giving the chaos simulator control over message routing.
  """

  alias Vor.Simulator.MessageProxy

  @doc """
  Start a supervisor with a Registry + one proxy per agent instance.
  `system_info` must include `:registry`, `:agents` (list of instance
  descriptors), and `:connections`.
  """
  def start_link(system_info) do
    children = build_children(system_info)

    # Chaos testing deliberately kills agents frequently. The default restart
    # intensity (3 restarts / 5s) treats that as a crash-loop and tears down the
    # WHOLE tree — including the Registry — which then makes discovery raise
    # `unknown registry` and crashes the fault injector. A generous intensity
    # lets the supervisor keep restarting killed agents (which is the point of
    # chaos), while a true init crash-loop would still eventually trip it.
    Supervisor.start_link(children,
      strategy: :one_for_one,
      max_restarts: 1_000_000,
      max_seconds: 1
    )
  end

  defp build_children(system_info) do
    registry_child = {Registry, keys: :unique, name: system_info.registry}

    agent_children =
      Enum.map(system_info.agents, fn agent_desc ->
        outbound =
          (system_info.connections || [])
          |> Enum.filter(fn %{from: from} -> from == agent_desc.name end)
          |> Enum.map(fn %{to: to} -> to end)

        # Build the args list the agent expects: params + system metadata
        agent_args =
          (agent_desc.params || []) ++
            [
              __vor_registry__: system_info.registry,
              __vor_name__: agent_desc.name,
              __vor_connections__: outbound
            ]

        proxy_opts = %{
          agent_module: agent_desc.module,
          agent_args: agent_args,
          agent_name: agent_desc.name,
          behaviour: agent_desc.behaviour,
          name: {:via, Registry, {system_info.registry, agent_desc.name}}
        }

        %{
          id: {:vor_proxy, agent_desc.name},
          start: {MessageProxy, :start_link, [proxy_opts]},
          restart: :permanent
        }
      end)

    [registry_child | agent_children]
  end
end
