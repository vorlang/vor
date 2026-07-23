defmodule Vor.Simulator do
  @moduledoc """
  Chaos simulation for Vor system blocks.

  Starts real OTP processes via a proxy-aware supervisor, injects faults
  (kill, partition, delay), and checks declared safety invariants against
  live state. Reports a timeline of events with pass/fail outcome and a
  reproducible seed.

  Phase 2 adds message interception via `Vor.Simulator.MessageProxy` —
  proxy processes between connected agents that can delay, drop, or
  partition messages.
  """

  alias Vor.Simulator.{Coverage, InvariantChecker, MessageProxy, SupervisorBuilder, Timeline, Workload}
  alias Vor.Explorer.Vacuity

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
  Config keys in `config` override chaos-block values from the file.
  Missing keys fall back to the file's chaos config, then to defaults.
  """
  def run_system(system_info, config) do
    config = merge_chaos_config(config, system_info[:chaos])
    :rand.seed(:exsss, {config.seed, config.seed + 1, config.seed + 2})
    Process.flag(:trap_exit, true)

    case start_requirements(system_info) do
      {:ok, req_pids} ->
        case SupervisorBuilder.start_link(system_info) do
          {:ok, sup_pid} ->
            # Attach the coverage collector before agents do meaningful work, so
            # early transitions/messages are observed (task 2b.2).
            collector = Coverage.start()

            Process.sleep(500)

            agent_pids = discover_agents(system_info)
            {:ok, timeline} = Timeline.start_link()

            Timeline.record(timeline, :start, %{
              agents: Map.keys(agent_pids),
              seed: config.seed
            })

            result = run_loop(agent_pids, system_info, config, timeline, sup_pid)

            coverage = Coverage.stop(collector, system_info)
            result = put_coverage(result, coverage)

            try do
              Supervisor.stop(sup_pid, :normal, 5000)
            catch
              :exit, _ -> :ok
            end

            stop_requirements(req_pids)
            result

          {:error, reason} ->
            stop_requirements(req_pids)
            {:error, :system_crash, reason}
        end

      {:error, dep, reason} ->
        {:error, :dependency_failed, dep, reason}
    end
  end

  # Fold the coverage report into whichever result shape run_loop returned.
  defp put_coverage({:ok, outcome, stats}, coverage),
    do: {:ok, outcome, Map.put(stats, :coverage, coverage)}

  defp put_coverage({:error, :violation, name, details, stats}, coverage),
    do: {:error, :violation, name, details, Map.put(stats, :coverage, coverage)}

  defp put_coverage(other, _coverage), do: other

  # -------------------------------------------------------------------
  # Simulation loop
  # -------------------------------------------------------------------

  defp run_loop(agent_pids, system_info, config, timeline, sup_pid) do
    deadline = System.monotonic_time(:millisecond) + config.duration_ms
    {:ok, pid_agent} = Agent.start_link(fn -> agent_pids end)

    injector =
      if config.inject_faults do
        Task.async(fn ->
          # `:rand.seed/2` sets the seed in the *current* process. The fault
          # loop runs in this Task, not the main process, so it must seed itself
          # or its random decisions (fault type, target, timing, duration) are
          # unseeded. Distinct offset per Task so their streams don't correlate.
          seed_process(config.seed, 1)
          fault_loop(pid_agent, system_info, config, timeline, sup_pid, deadline)
        end)
      end

    checker =
      Task.async(fn ->
        invariant_loop(pid_agent, system_info, config, timeline, deadline)
      end)

    workload_rate = Map.get(config, :workload_rate, 0)

    workload_task =
      if workload_rate > 0 do
        Task.async(fn ->
          seed_process(config.seed, 2)
          Workload.run(pid_agent, system_info, config, timeline, deadline)
        end)
      end

    Process.sleep(config.duration_ms)

    # Execution-integrity: capture whether each harness Task crashed (vs was
    # shut down normally). A crashed fault injector / checker / workload means
    # the run silently exercised less than it claimed (the "Seed 7" problem).
    injector_status = task_status(injector, :brutal_kill)
    checker_status = task_status(checker, 5000)
    workload_status = task_status(workload_task, :brutal_kill)

    Agent.stop(pid_agent)

    events = Timeline.get(timeline)
    Agent.stop(timeline)

    integrity =
      assess_integrity(config, events, [
        {:fault_injector, injector_status},
        {:invariant_checker, checker_status},
        {:workload, workload_status}
      ])

    stats =
      events
      |> compute_stats()
      |> Map.put(:events, events)
      |> Map.put(:integrity, integrity)
      |> Map.put(:relevance, assess_relevance(events, system_info[:invariants] || []))

    case find_violation(events) do
      # A found violation is a real bug even if the harness later degraded.
      {name, details} -> {:error, :violation, name, details, stats}
      # A pass whose harness degraded is UNDER-TESTED, not a clean pass.
      nil -> if integrity.degraded?, do: {:ok, :under_tested, stats}, else: {:ok, :pass, stats}
    end
  end

  # A harness Task's fate. `nil`/`:killed`/`:shutdown`/`:normal` = shut down or
  # still running (healthy); any other exit reason = it crashed.
  defp task_status(nil, _shutdown), do: :not_started

  defp task_status(task, shutdown) do
    case Task.yield(task, 0) || Task.shutdown(task, shutdown) do
      {:ok, _} -> :completed
      nil -> :running
      {:exit, reason} when reason in [:normal, :shutdown, :killed] -> :running
      {:exit, reason} -> {:crashed, reason}
    end
  end

  # Did the run actually exercise what it claimed? A degraded run must not read
  # as a clean pass. Signals: a harness component crashed; no invariant check
  # ran; or (with faults enabled) not a single fault was injected.
  defp assess_integrity(config, events, task_statuses) do
    faults_enabled = Map.get(config, :inject_faults, true)

    injected =
      Enum.count(events, fn {_, t, _} -> t in [:kill, :partition_start, :delay_start] end)

    checks_run = Enum.count(events, fn {_, t, _} -> t in [:check_ok, :violation] end)

    check_interval = Map.get(config, :check_interval_ms, 1000)
    checks_planned = if check_interval > 0, do: div(config.duration_ms, check_interval), else: 0

    crashes = for {name, {:crashed, reason}} <- task_statuses, do: {name, reason}

    reasons =
      []
      |> maybe(crashes != [], "harness component(s) crashed: #{inspect(Enum.map(crashes, &elem(&1, 0)))}")
      |> maybe(checks_run == 0, "no invariant checks ran")
      |> maybe(faults_enabled and injected == 0, "fault injection was requested but no faults were injected")

    %{
      degraded?: reasons != [],
      reasons: Enum.reverse(reasons),
      faults_injected: injected,
      invariant_checks: checks_run,
      checks_planned: checks_planned,
      harness_crashes: crashes
    }
  end

  defp maybe(list, true, reason), do: [reason | list]
  defp maybe(list, false, _reason), do: list

  # Relevance axis (Phase 2b, task 2b.3): for each invariant, in how many of the
  # live checks was its *subject* actually true? A pass over samples where the
  # subject never appears is vacuous — the same notion the model checker applies
  # to explored states, here applied to observed live state. Each `:check_ok` /
  # `:violation` event carries a `subject_active` map recorded by the checker.
  defp assess_relevance(events, invariants) do
    samples =
      for {_, t, d} <- events,
          t in [:check_ok, :violation],
          is_map(d),
          Map.has_key?(d, :subject_active),
          do: d.subject_active

    total = length(samples)

    Enum.map(invariants, fn inv ->
      live = Enum.count(samples, fn sa -> Map.get(sa, inv.name, false) end)

      relevance =
        cond do
          total == 0 -> :unexercised
          live > 0 -> :substantive
          true -> :vacuous
        end

      %{
        name: inv.name,
        relevance: relevance,
        subject_live_checks: live,
        total_checks: total,
        subject: describe_invariant_subject(inv)
      }
    end)
  end

  defp describe_invariant_subject(%{body: body}) do
    try do
      Vacuity.describe_subject(body)
    rescue
      _ -> "(subject)"
    end
  end

  defp describe_invariant_subject(_), do: "(subject)"

  # Seed a Task's own `:rand` state deterministically from the run seed, with a
  # per-Task offset so the fault and workload streams are independent.
  defp seed_process(seed, offset) do
    :rand.seed(:exsss, {seed * 3 + offset, seed * 5 + offset, seed * 7 + offset})
  end

  # -------------------------------------------------------------------
  # Fault injection
  # -------------------------------------------------------------------

  defp fault_loop(pid_agent, system_info, config, timeline, sup_pid, deadline) do
    fault_interval = Map.get(config, :fault_interval, config.kill_interval)
    {f_min, f_max} = fault_interval
    interval = f_min + :rand.uniform(max(f_max - f_min, 1))
    Process.sleep(interval)

    if System.monotonic_time(:millisecond) < deadline do
      fault_type = choose_fault_type(config)

      case fault_type do
        :kill ->
          inject_kill(pid_agent, system_info, timeline, sup_pid)

        :partition ->
          inject_partition(pid_agent, config, timeline)

        :delay ->
          inject_delay(pid_agent, config, timeline)
      end

      # Test-only hook: crash the fault loop after injecting one fault, to
      # exercise the execution-integrity / UNDER-TESTED path (the Seed-7 case).
      if Map.get(config, :__crash_fault_loop__, false) do
        raise "vor test: forced fault-loop crash"
      end

      fault_loop(pid_agent, system_info, config, timeline, sup_pid, deadline)
    end
  end

  defp choose_fault_type(config) do
    types = [:kill]
    types = if Map.get(config, :enable_partitions, false), do: types ++ [:partition], else: types
    types = if Map.get(config, :enable_delays, false), do: types ++ [:delay], else: types
    Enum.random(types)
  end

  defp inject_kill(pid_agent, system_info, timeline, _sup_pid) do
    pids = Agent.get(pid_agent, & &1)

    if map_size(pids) > 0 do
      {name, pid} = Enum.random(pids)
      Timeline.record(timeline, :kill, %{agent: name, pid: pid})

      if is_pid(pid) and Process.alive?(pid), do: Process.exit(pid, :kill)

      Process.sleep(300)

      new_pids = discover_agents(system_info)
      Agent.update(pid_agent, fn _ -> new_pids end)
      Timeline.record(timeline, :restart, %{agent: name})
    end
  end

  defp inject_partition(pid_agent, config, timeline) do
    pids = Agent.get(pid_agent, & &1)
    agents = Map.keys(pids)

    if length(agents) > 1 do
      isolated = Enum.random(agents)
      Timeline.record(timeline, :partition_start, %{isolated: isolated})

      proxy_pid = pids[isolated]

      try do
        MessageProxy.set_policy(proxy_pid, %{policy: :partition})
      catch
        :exit, _ -> :ok
      end

      {dur_min, dur_max} = Map.get(config, :partition_duration, {1000, 5000})
      duration = dur_min + :rand.uniform(max(dur_max - dur_min, 1))
      Process.sleep(duration)

      try do
        MessageProxy.set_policy(proxy_pid, %{policy: :forward})
      catch
        :exit, _ -> :ok
      end

      Timeline.record(timeline, :partition_end, %{isolated: isolated, duration_ms: duration})
    end
  end

  defp inject_delay(pid_agent, config, timeline) do
    pids = Agent.get(pid_agent, & &1)

    if map_size(pids) > 0 do
      {name, proxy_pid} = Enum.random(pids)
      delay_range = Map.get(config, :delay_range, 50..200)

      Timeline.record(timeline, :delay_start, %{agent: name, range_ms: delay_range})

      try do
        MessageProxy.set_policy(proxy_pid, %{policy: :delay, delay_range: delay_range})
      catch
        :exit, _ -> :ok
      end

      {dur_min, dur_max} = Map.get(config, :delay_duration, {2000, 5000})
      duration = dur_min + :rand.uniform(max(dur_max - dur_min, 1))
      Process.sleep(duration)

      try do
        MessageProxy.set_policy(proxy_pid, %{policy: :forward})
      catch
        :exit, _ -> :ok
      end

      Timeline.record(timeline, :delay_end, %{agent: name})
    end
  end

  # -------------------------------------------------------------------
  # Invariant checking
  # -------------------------------------------------------------------

  defp invariant_loop(pid_agent, system_info, config, timeline, deadline) do
    Process.sleep(config.check_interval_ms)

    if System.monotonic_time(:millisecond) < deadline do
      pids = Agent.get(pid_agent, & &1)

      # Get real agent PIDs through the proxies
      real_pids = get_real_pids(pids)

      result = InvariantChecker.check(real_pids, system_info.agent_info, system_info.invariants)

      case result do
        {:ok, subject_active} ->
          Timeline.record(timeline, :check_ok, %{subject_active: subject_active})

        {:violation, name, agent_states, subject_active} ->
          recent = Timeline.recent(timeline, 10)

          Timeline.record(timeline, :violation, %{
            name: name,
            agent_states: agent_states,
            subject_active: subject_active,
            recent_events: recent
          })
      end

      invariant_loop(pid_agent, system_info, config, timeline, deadline)
    end
  end

  defp get_real_pids(proxy_pids) do
    Enum.into(proxy_pids, %{}, fn {name, proxy_pid} ->
      real =
        try do
          MessageProxy.get_real_pid(proxy_pid)
        catch
          :exit, _ -> proxy_pid
        end

      {name, real}
    end)
  end

  # -------------------------------------------------------------------
  # Requirement startup and shutdown
  # -------------------------------------------------------------------

  defp start_requirements(%{requires: requires}) when is_list(requires) and requires != [] do
    Enum.reduce_while(requires, {:ok, []}, fn req, {:ok, pids} ->
      case start_requirement(req) do
        {:ok, pid} ->
          {:cont, {:ok, [{req, pid} | pids]}}

        {:error, reason} ->
          Enum.each(pids, fn {_, pid} -> stop_one_req(pid) end)
          {:halt, {:error, req.target, reason}}
      end
    end)
    |> case do
      {:ok, pids} -> {:ok, Enum.reverse(pids)}
      error -> error
    end
  end

  defp start_requirements(_), do: {:ok, []}

  defp start_requirement(%{type: :application, target: app}) do
    case Application.ensure_all_started(app) do
      {:ok, _} -> {:ok, app}
      {:error, {_, {:already_started, _}}} -> {:ok, app}
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_requirement(%{type: :module, target: module, args: args}) do
    args = args || []

    cond do
      Code.ensure_loaded?(module) and function_exported?(module, :start_link, 1) ->
        case module.start_link(args) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end

      Code.ensure_loaded?(module) and function_exported?(module, :start_link, 0) ->
        case module.start_link() do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:error, {:no_start_function, module}}
    end
  end

  defp stop_requirements(req_pids) do
    req_pids
    |> Enum.reverse()
    |> Enum.each(fn {_req, pid} -> stop_one_req(pid) end)
  end

  defp stop_one_req(app) when is_atom(app) do
    try do
      Application.stop(app)
    catch
      _, _ -> :ok
    end
  end

  defp stop_one_req(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 5000)
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp stop_one_req(_), do: :ok

  # -------------------------------------------------------------------
  # System startup and discovery
  # -------------------------------------------------------------------

  defp discover_agents(%{agent_names: names, registry: registry}) do
    Enum.reduce(names, %{}, fn name, acc ->
      case safe_lookup(registry, name) do
        [{pid, _}] -> Map.put(acc, name, pid)
        _ -> acc
      end
    end)
  end

  # `Registry.lookup/2` raises `ArgumentError` if the registry itself is not
  # running (e.g. torn down by a supervisor restart storm). Discovery races with
  # chaos, so treat an unavailable registry as "no entry" rather than crashing
  # the caller — the supervisor-intensity fix keeps the registry alive, this is
  # defense-in-depth for any transient window.
  defp safe_lookup(registry, name) do
    Registry.lookup(registry, name)
  rescue
    ArgumentError -> []
  end

  # -------------------------------------------------------------------
  # Stats and violations
  # -------------------------------------------------------------------

  defp compute_stats(events) do
    %{
      faults_injected:
        Enum.count(events, fn {_, type, _} -> type in [:kill, :partition_start, :delay_start] end),
      invariant_checks:
        Enum.count(events, fn {_, type, _} -> type in [:check_ok, :violation] end),
      violations: Enum.count(events, fn {_, type, _} -> type == :violation end),
      restarts: Enum.count(events, fn {_, type, _} -> type == :restart end),
      partitions: Enum.count(events, fn {_, type, _} -> type == :partition_start end),
      delays: Enum.count(events, fn {_, type, _} -> type == :delay_start end),
      workload_sent:
        Enum.count(events, fn {_, type, _} -> type in [:workload_ok, :workload_error, :workload_timeout] end),
      workload_ok:
        Enum.count(events, fn {_, type, _} -> type == :workload_ok end),
      workload_errors:
        Enum.count(events, fn {_, type, _} -> type == :workload_error end),
      workload_timeouts:
        Enum.count(events, fn {_, type, _} -> type == :workload_timeout end)
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
        agents =
          Enum.map(result.system_ir.agents, fn instance ->
            case Map.get(result.agents, instance.type_name) do
              %{ir: ir} ->
                %{
                  name: instance.name,
                  module: ir.module,
                  behaviour: ir.behaviour,
                  params: instance.params
                }

              _ ->
                %{
                  name: instance.name,
                  module: Module.concat([Vor, Agent, instance.type_name]),
                  behaviour: :gen_server,
                  params: instance.params
                }
            end
          end)

        agent_info =
          Enum.into(agents, %{}, fn agent ->
            enum_field =
              case Map.get(result.agents, agent_type_for(result.system_ir, agent.name)) do
                %{ir: ir} ->
                  case ir.state_fields do
                    [%{name: name} | _] -> name
                    _ -> nil
                  end

                _ ->
                  nil
              end

            {agent.name, %{module: agent.module, enum_field: enum_field, behaviour: agent.behaviour}}
          end)

        accepts_by_name =
          Enum.into(result.system_ir.agents, %{}, fn instance ->
            case Map.get(result.agents, instance.type_name) do
              %{ir: ir} when not is_nil(ir.protocol) ->
                accepts =
                  Enum.map(ir.protocol.accepts || [], fn msg_type ->
                    %{
                      tag: msg_type.tag,
                      fields: msg_type.fields
                    }
                  end)

                {instance.name, accepts}

              _ ->
                {instance.name, []}
            end
          end)

        {:ok,
         %{
           registry: result.system.registry,
           agents: agents,
           agent_names: Enum.map(agents, & &1.name),
           agent_info: agent_info,
           accepts_by_name: accepts_by_name,
           declared_surface: declared_surface(result),
           connections: result.system_ir.connections,
           invariants: result.system_ir.invariants,
           chaos: result.system_ir.chaos,
           requires: result.system_ir.requires || []
         }}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  The per-instance declared surface stored in a compiled `system_info` (enum
  state values, handler tags, accepted/emitted message tags). Used by sweep
  aggregation to compute union coverage against a stable declaration.
  """
  def declared_surface_for(system_info), do: system_info[:declared_surface] || %{}

  # Per-instance declared surface for coverage (Phase 2b, task 2b.2): enum state
  # values, handler tags, accepted and emitted message tags. Keyed by instance
  # name to match the `agent` field telemetry carries (`__vor_agent_name__`).
  defp declared_surface(result) do
    Enum.into(result.system_ir.agents, %{}, fn instance ->
      surface =
        case Map.get(result.agents, instance.type_name) do
          %{ir: ir} ->
            %{
              states: declared_states(ir.state_fields),
              handlers: declared_handler_tags(ir.handlers),
              accepts: declared_msg_tags(ir.protocol, :accepts),
              emits: declared_msg_tags(ir.protocol, :emits)
            }

          _ ->
            %{states: %{}, handlers: [], accepts: [], emits: []}
        end

      {instance.name, surface}
    end)
  end

  # Only enum state fields (a union of atom values) contribute reachable states.
  defp declared_states(nil), do: %{}

  defp declared_states(state_fields) do
    Enum.reduce(state_fields || [], %{}, fn
      %{name: name, values: values}, acc when is_list(values) and length(values) > 1 ->
        if Enum.all?(values, &is_atom/1), do: Map.put(acc, name, values), else: acc

      _, acc ->
        acc
    end)
  end

  defp declared_handler_tags(nil), do: []

  defp declared_handler_tags(handlers) do
    handlers
    |> Enum.map(fn h -> h.pattern && h.pattern.tag end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp declared_msg_tags(nil, _key), do: []

  defp declared_msg_tags(protocol, key) do
    (Map.get(protocol, key) || [])
    |> Enum.map(& &1.tag)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp agent_type_for(system_ir, instance_name) do
    case Enum.find(system_ir.agents, fn a -> a.name == instance_name end) do
      nil -> nil
      inst -> inst.type_name
    end
  end

  # -------------------------------------------------------------------
  # Merge chaos-block file config with CLI-provided config.
  # CLI keys take precedence; missing keys fall back to the file's chaos
  # block, then to sensible defaults.
  # -------------------------------------------------------------------

  defp merge_chaos_config(cli, nil), do: apply_defaults(cli)
  defp merge_chaos_config(cli, %Vor.IR.ChaosConfig{} = file), do: merge_chaos_config(cli, Map.from_struct(file))
  defp merge_chaos_config(cli, file) when is_map(file) do
    defaults = %{
      duration_ms: file[:duration_ms] || 30_000,
      seed: file[:seed] || :rand.uniform(1_000_000),
      kill_interval: chaos_kill_interval(file[:kill]),
      fault_interval: chaos_kill_interval(file[:kill]),
      check_interval_ms: chaos_check_interval(file[:check]),
      inject_faults: true,
      enable_partitions: file[:partition] != nil,
      enable_delays: file[:delay] != nil,
      partition_duration: chaos_partition_duration(file[:partition]),
      delay_range: chaos_delay_range(file[:delay]),
      workload_rate: chaos_workload_rate(file[:workload]),
      verbose: false
    }

    # CLI values override file defaults
    Map.merge(defaults, cli)
  end

  defp apply_defaults(config) do
    defaults = %{
      duration_ms: 30_000,
      seed: :rand.uniform(1_000_000),
      kill_interval: {3000, 10000},
      fault_interval: {3000, 10000},
      check_interval_ms: 1000,
      inject_faults: true,
      enable_partitions: false,
      enable_delays: false,
      partition_duration: {1000, 5000},
      delay_range: 50..200,
      workload_rate: 0,
      verbose: false
    }

    Map.merge(defaults, config)
  end

  defp chaos_kill_interval(nil), do: {3000, 10000}
  defp chaos_kill_interval(%{every: {min, max}}), do: {min, max}
  defp chaos_kill_interval(_), do: {3000, 10000}

  defp chaos_check_interval(nil), do: 1000
  defp chaos_check_interval(%{every: ms}), do: ms
  defp chaos_check_interval(_), do: 1000

  defp chaos_partition_duration(nil), do: {1000, 5000}
  defp chaos_partition_duration(%{duration: {min, max}}), do: {min, max}
  defp chaos_partition_duration(_), do: {1000, 5000}

  defp chaos_delay_range(nil), do: 50..200
  defp chaos_delay_range(%{by: {min, max}}), do: min..max
  defp chaos_delay_range(_), do: 50..200

  defp chaos_workload_rate(nil), do: 0
  defp chaos_workload_rate(%{rate: r}), do: r
  defp chaos_workload_rate(_), do: 0
end
