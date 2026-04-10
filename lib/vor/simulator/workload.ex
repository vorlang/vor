defmodule Vor.Simulator.Workload do
  @moduledoc """
  Generates client workload during chaos simulation.

  Sends messages matching agent `accepts` declarations at a configurable
  rate. Responses are collected and errors/timeouts counted. Runs as a
  parallel task alongside the fault injector and invariant checker.
  """

  alias Vor.Simulator.Timeline

  def run(pid_agent, system_info, config, timeline, deadline) do
    rate_ms = if config.workload_rate > 0, do: div(1000, config.workload_rate), else: 1000
    stats = %{sent: 0, ok: 0, errors: 0, timeouts: 0}
    loop(pid_agent, system_info, config, timeline, deadline, rate_ms, stats)
  end

  defp loop(pid_agent, system_info, config, timeline, deadline, rate_ms, stats) do
    if System.monotonic_time(:millisecond) >= deadline do
      stats
    else
      agent_pids = Agent.get(pid_agent, & &1)

      new_stats =
        if map_size(agent_pids) > 0 do
          {name, pid} = Enum.random(agent_pids)
          accepts = Map.get(system_info.accepts_by_name, name, [])

          if accepts != [] do
            decl = Enum.random(accepts)
            msg = build_message(decl, stats.sent)
            {_result, s} = send_request(pid, msg, name, stats, timeline, config)
            s
          else
            stats
          end
        else
          stats
        end

      Process.sleep(rate_ms)
      loop(pid_agent, system_info, config, timeline, deadline, rate_ms, new_stats)
    end
  end

  defp send_request(pid, msg, agent_name, stats, timeline, _config) do
    try do
      _result = GenServer.call(pid, msg, 2000)
      Timeline.record(timeline, :workload_ok, %{agent: agent_name, msg: elem(msg, 0)})
      {:ok, %{stats | sent: stats.sent + 1, ok: stats.ok + 1}}
    catch
      :exit, {:timeout, _} ->
        Timeline.record(timeline, :workload_timeout, %{agent: agent_name, msg: elem(msg, 0)})
        {:timeout, %{stats | sent: stats.sent + 1, timeouts: stats.timeouts + 1}}

      :exit, _reason ->
        Timeline.record(timeline, :workload_error, %{agent: agent_name, msg: elem(msg, 0)})
        {:error, %{stats | sent: stats.sent + 1, errors: stats.errors + 1}}
    end
  end

  defp build_message(%{tag: tag, fields: fields}, seq) do
    tag_atom = if is_atom(tag), do: tag, else: String.to_atom("#{tag}")

    field_map =
      Enum.into(fields || [], %{}, fn {name, type} ->
        name_atom = if is_atom(name), do: name, else: String.to_atom("#{name}")
        {name_atom, representative_value(type, name_atom, seq)}
      end)

    {tag_atom, field_map}
  end

  defp representative_value(:atom, :client, seq), do: :"client_#{rem(seq, 10)}"
  defp representative_value(:atom, :node_id, seq), do: :"node_#{rem(seq, 5)}"
  defp representative_value(:atom, :candidate_id, seq), do: :"node_#{rem(seq, 3)}"
  defp representative_value(:atom, :leader_id, seq), do: :"node_#{rem(seq, 3)}"
  defp representative_value(:atom, :voter, seq), do: :"node_#{rem(seq, 3)}"
  defp representative_value(:atom, :follower, seq), do: :"node_#{rem(seq, 3)}"
  defp representative_value(:atom, _name, _seq), do: :test
  defp representative_value(:integer, :term, seq), do: rem(seq, 5) + 1
  defp representative_value(:integer, _name, seq), do: rem(seq, 100)
  defp representative_value(:binary, :client, seq), do: "client_#{rem(seq, 10)}"
  defp representative_value(:binary, _name, _seq), do: "test"
  defp representative_value(:term, :payload, _seq), do: :test_payload
  defp representative_value(:term, :command, _seq), do: :test_command
  defp representative_value(:term, _name, _seq), do: nil
  defp representative_value(:list, _name, _seq), do: []
  defp representative_value(:map, _name, _seq), do: %{}
  defp representative_value(_, _name, _seq), do: nil
end
