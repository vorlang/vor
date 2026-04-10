defmodule Vor.Simulator do
  @moduledoc """
  Chaos simulation for Vor system blocks.

  Starts real OTP processes via the system's supervisor, periodically kills
  random agents (letting supervisors restart them), and checks declared
  safety invariants against live state. Reports a timeline of events with
  pass/fail outcome and seed for reproducibility.

  Phase 1 scope: kill injection + invariant checking. No message
  interception, no workload generation, no chaos-block syntax.
  """

  alias Vor.Simulator.{InvariantChecker, Timeline}

  @doc """
  Compile, load, and simulate a `.vor` file containing a system block.
  """
  def run_file(file, config) do
    source = File.read!(file)

    case compile_for_simulation(source) do
      {:ok, system_info} -> run_system(system_info, config)
      {:error, _} = err -> err
    end
  end

  @doc """
  Run the simulation against an already-compiled system.
  """
  def run_system(system_info, config) do
    :rand.seed(:exsss, {config.seed, config.seed + 1, config.seed + 2})
    # Trap exits so a supervisor crash during kill injection doesn't take
    # down the simulator process.
    Process.flag(:trap_exit, true)

    case start_system(system_info) do
      {:ok, sup_pid} ->
        Process.sleep(500)

        agent_pids = discover_agents(system_info)
        {:ok, timeline} = Timeline.start_link()

        Timeline.record(timeline, :start, %{
          agents: Map.keys(agent_pids),
          seed: config.seed
        })

        result = run_loop(agent_pids, system_info, config, timeline, sup_pid)

        try do
          Supervisor.stop(sup_pid, :normal, 5000)
        catch
          :exit, _ -> :ok
        end

        result

      {:error, reason} ->
        {:error, :system_crash, reason}
    end
  end

  # -------------------------------------------------------------------
  # Simulation loop
  # -------------------------------------------------------------------

  defp run_loop(agent_pids, system_info, config, timeline, sup_pid) do
    deadline = System.monotonic_time(:millisecond) + config.duration_ms
    {:ok, pid_agent} = Agent.start_link(fn -> agent_pids end)

    injector =
      if config.inject_faults do
        Task.async(fn ->
          fault_loop(pid_agent, system_info, config, timeline, sup_pid, deadline)
        end)
      end

    checker =
      Task.async(fn ->
        invariant_loop(pid_agent, system_info, config, timeline, deadline)
      end)

    Process.sleep(config.duration_ms)

    if injector, do: Task.shutdown(injector, :brutal_kill)
    Task.shutdown(checker, 5000)
    Agent.stop(pid_agent)

    events = Timeline.get(timeline)
    Agent.stop(timeline)
    stats = compute_stats(events)

    case find_violation(events) do
      nil -> {:ok, :pass, stats}
      {name, details} -> {:error, :violation, name, details, stats}
    end
  end

  # -------------------------------------------------------------------
  # Fault injection
  # -------------------------------------------------------------------

  defp fault_loop(pid_agent, system_info, config, timeline, sup_pid, deadline) do
    {kill_min, kill_max} = config.kill_interval
    interval = kill_min + :rand.uniform(max(kill_max - kill_min, 1))
    Process.sleep(interval)

    if System.monotonic_time(:millisecond) < deadline do
      pids = Agent.get(pid_agent, & &1)

      if map_size(pids) > 0 do
        {name, pid} = Enum.random(pids)
        Timeline.record(timeline, :kill, %{agent: name, pid: pid})

        if is_pid(pid) and Process.alive?(pid) do
          Process.exit(pid, :kill)
        end

        Process.sleep(300)

        new_pids = discover_agents(system_info)
        Agent.update(pid_agent, fn _ -> new_pids end)
        Timeline.record(timeline, :restart, %{agent: name})
      end

      fault_loop(pid_agent, system_info, config, timeline, sup_pid, deadline)
    end
  end

  # -------------------------------------------------------------------
  # Invariant checking
  # -------------------------------------------------------------------

  defp invariant_loop(pid_agent, system_info, config, timeline, deadline) do
    Process.sleep(config.check_interval_ms)

    if System.monotonic_time(:millisecond) < deadline do
      pids = Agent.get(pid_agent, & &1)
      result = InvariantChecker.check(pids, system_info.agent_info, system_info.invariants)

      case result do
        :ok ->
          Timeline.record(timeline, :check_ok)

        {:violation, name, agent_states} ->
          recent = Timeline.recent(timeline, 10)

          Timeline.record(timeline, :violation, %{
            name: name,
            agent_states: agent_states,
            recent_events: recent
          })
      end

      invariant_loop(pid_agent, system_info, config, timeline, deadline)
    end
  end

  # -------------------------------------------------------------------
  # System startup and discovery
  # -------------------------------------------------------------------

  defp start_system(%{start_link: start_fn}) do
    try do
      start_fn.()
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp discover_agents(%{agent_names: names, registry: registry}) do
    Enum.reduce(names, %{}, fn name, acc ->
      case Registry.lookup(registry, name) do
        [{pid, _}] -> Map.put(acc, name, pid)
        _ -> acc
      end
    end)
  end

  # -------------------------------------------------------------------
  # Stats and violations
  # -------------------------------------------------------------------

  defp compute_stats(events) do
    %{
      faults_injected: Enum.count(events, fn {_, type, _} -> type == :kill end),
      invariant_checks: Enum.count(events, fn {_, type, _} -> type in [:check_ok, :violation] end),
      violations: Enum.count(events, fn {_, type, _} -> type == :violation end),
      restarts: Enum.count(events, fn {_, type, _} -> type == :restart end)
    }
  end

  defp find_violation(events) do
    Enum.find_value(events, fn
      {_, :violation, %{name: name} = details} -> {name, details}
      _ -> nil
    end)
  end

  # -------------------------------------------------------------------
  # Compilation bridge
  # -------------------------------------------------------------------

  @doc false
  def compile_for_simulation(source) do
    case Vor.Compiler.compile_system_and_load(source) do
      {:ok, result} ->
        agent_info =
          Enum.into(result.system_ir.agents, %{}, fn instance ->
            case Map.get(result.agents, instance.type_name) do
              %{ir: ir} ->
                enum_field =
                  case ir.state_fields do
                    [%{name: name} | _] -> name
                    _ -> nil
                  end

                {instance.name,
                 %{module: ir.module, enum_field: enum_field, behaviour: ir.behaviour}}

              _ ->
                {instance.name, %{module: nil, enum_field: nil, behaviour: :gen_server}}
            end
          end)

        {:ok,
         %{
           system_module: result.system.module,
           registry: result.system.registry,
           start_link: result.system.start_link,
           agent_names: Enum.map(result.system_ir.agents, & &1.name),
           agent_info: agent_info,
           invariants: result.system_ir.invariants
         }}

      {:error, _} = err ->
        err
    end
  end
end
