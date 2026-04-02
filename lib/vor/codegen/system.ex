defmodule Vor.Codegen.System do
  @moduledoc """
  Generates OTP Supervisor + Registry modules for Vor system blocks.
  """

  alias Vor.IR

  @doc """
  Generate Erlang abstract format for the system supervisor module.
  """
  def generate(%IR.SystemIR{} = system, agent_irs) do
    l = 1
    module = Module.concat([Vor, System, system.name])
    registry = Module.concat([Vor, System, system.name, Registry])

    forms = List.flatten([
      {:attribute, l, :file, {~c"#{system.name}.vor", l}},
      {:attribute, l, :module, module},
      {:attribute, l, :behaviour, :supervisor},
      {:attribute, l, :export, [{:start_link, 0}, {:init, 1}]},
      gen_start_link(module, l),
      gen_init(system, registry, agent_irs, l)
    ])

    {:ok, forms, %{module: module, registry: registry}}
  end

  defp gen_start_link(module, l) do
    {:function, l, :start_link, 0, [
      {:clause, l, [], [], [
        {:call, l,
          {:remote, l, {:atom, l, :supervisor}, {:atom, l, :start_link}},
          [{:tuple, l, [{:atom, l, :local}, {:atom, l, module}]},
           {:atom, l, module}, {:nil, l}]}
      ]}
    ]}
  end

  defp gen_init(system, registry, agent_irs, l) do
    # Registry child spec
    registry_child = gen_registry_child(registry, l)

    # Agent child specs — reverse dependency order (sinks first)
    agent_children = system.agents
    |> order_by_dependencies(system.connections)
    |> Enum.map(fn agent_inst ->
      agent_ir = Map.get(agent_irs, agent_inst.name)
      gen_agent_child(agent_inst, agent_ir, registry, l)
    end)

    children = list_to_erl([registry_child | agent_children], l)

    sup_flags = {:map, l, [
      {:map_field_assoc, l, {:atom, l, :strategy}, {:atom, l, :one_for_all}},
      {:map_field_assoc, l, {:atom, l, :intensity}, {:integer, l, 3}},
      {:map_field_assoc, l, {:atom, l, :period}, {:integer, l, 5}}
    ]}

    {:function, l, :init, 1, [
      {:clause, l, [{:var, l, :_Args}], [], [
        {:tuple, l, [{:atom, l, :ok}, {:tuple, l, [sup_flags, children]}]}
      ]}
    ]}
  end

  defp gen_registry_child(registry, l) do
    {:map, l, [
      {:map_field_assoc, l, {:atom, l, :id}, {:atom, l, registry}},
      {:map_field_assoc, l, {:atom, l, :start},
        {:tuple, l, [
          {:atom, l, Registry},
          {:atom, l, :start_link},
          {_cons, _, _, _} = list_to_erl([
            list_to_erl([
              {:tuple, l, [{:atom, l, :keys}, {:atom, l, :unique}]},
              {:tuple, l, [{:atom, l, :name}, {:atom, l, registry}]}
            ], l)
          ], l)
        ]}}
    ]}
  end

  defp gen_agent_child(agent_inst, agent_ir, registry, l) do
    agent_module = if agent_ir, do: agent_ir.module, else: Module.concat([Vor, Agent, agent_inst.type_name])
    behaviour = if agent_ir, do: agent_ir.behaviour, else: :gen_server

    # Build init args: agent params + system metadata
    param_args = Enum.flat_map(agent_inst.params, fn {name, value} ->
      [{:tuple, l, [{:atom, l, name}, value_literal(value, l)]}]
    end)

    system_args = [
      {:tuple, l, [{:atom, l, :__vor_registry__}, {:atom, l, registry}]},
      {:tuple, l, [{:atom, l, :__vor_name__}, {:atom, l, agent_inst.name}]}
    ]

    args_list = list_to_erl(param_args ++ system_args, l)

    # Process name via Registry
    via_tuple = {:tuple, l, [
      {:atom, l, :via},
      {:atom, l, Registry},
      {:tuple, l, [{:atom, l, registry}, {:atom, l, agent_inst.name}]}
    ]}

    # Start function depends on behaviour
    start_fn = case behaviour do
      :gen_server ->
        {:tuple, l, [
          {:atom, l, :gen_server},
          {:atom, l, :start_link},
          list_to_erl([via_tuple, {:atom, l, agent_module}, args_list, {:nil, l}], l)
        ]}

      :gen_statem ->
        {:tuple, l, [
          {:atom, l, :gen_statem},
          {:atom, l, :start_link},
          list_to_erl([via_tuple, {:atom, l, agent_module}, args_list, {:nil, l}], l)
        ]}
    end

    {:map, l, [
      {:map_field_assoc, l, {:atom, l, :id}, {:atom, l, agent_inst.name}},
      {:map_field_assoc, l, {:atom, l, :start}, start_fn}
    ]}
  end

  # Order agents so receivers come before senders
  defp order_by_dependencies(agents, connections) do
    # Simple topological sort: agents with no outgoing connections first
    senders = MapSet.new(connections, fn %{from: f} -> f end)

    {non_senders, sender_agents} = Enum.split_with(agents, fn a ->
      not MapSet.member?(senders, a.name)
    end)

    non_senders ++ sender_agents
  end

  defp value_literal(value, l) when is_integer(value), do: {:integer, l, value}
  defp value_literal(value, l) when is_atom(value), do: {:atom, l, value}
  defp value_literal(value, l) when is_binary(value), do: {:bin, l, [{:bin_element, l, {:string, l, String.to_charlist(value)}, :default, :default}]}
  defp value_literal({:atom, value}, l), do: {:atom, l, String.to_atom(value)}

  defp list_to_erl([], l), do: {:nil, l}
  defp list_to_erl([h | t], l), do: {:cons, l, h, list_to_erl(t, l)}
end
