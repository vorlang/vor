defmodule Vor.Simulator.MonitoredWatch do
  @moduledoc """
  The monitored tier's violation-reporting channel (F13).

  Before this existed, `monitored(within:)` was fire-and-forget: a deadline
  exceeded and a resilience handler firing produced no signal, so a broken
  recovery degraded the system silently and the run stayed green. The compiler
  now emits `[:vor, :monitored, :deadline_exceeded]` and
  `[:vor, :monitored, :resilience_fired]` (the latter carrying `restores_target`,
  set when the recovery returns the agent to a good, non-monitored state). This
  collector consumes them so a run can report, per monitored invariant:

    - `deadline_exceeded → recovered` — the tier working, made visible; or
    - a **violation** — a deadline was exceeded and the recovery did *not*
      restore a good state (the agent is stuck), so the guarantee failed.

  ETS-backed and dedup-by-key like `Vor.Simulator.Coverage`, so a tight requeue
  loop firing the same event repeatedly is recorded once.
  """

  @events [
    [:vor, :monitored, :deadline_exceeded],
    [:vor, :monitored, :resilience_fired]
  ]

  @doc "Start the collector: create the table and attach handlers. Returns a handle."
  def start do
    table = :ets.new(:vor_monitored, [:set, :public, {:write_concurrency, true}])
    handler_id = {:vor_sim_monitored, make_ref()}
    :telemetry.attach_many(handler_id, @events, &__MODULE__.handle_event/4, table)
    %{table: table, handler_id: handler_id}
  end

  @doc "Detach, read the observations, and build the per-invariant report."
  def stop(%{table: table, handler_id: handler_id}) do
    :telemetry.detach(handler_id)
    report = build_report(:ets.tab2list(table))
    :ets.delete(table)
    report
  end

  @doc false
  # Runs inline in the emitting agent process — cheap, must not raise.
  def handle_event([:vor, :monitored, :deadline_exceeded], _measurements, meta, table) do
    inv = Map.get(meta, :invariant)
    agent = Map.get(meta, :agent)
    if inv, do: :ets.insert(table, {{:deadline, inv, agent}})
    :ok
  rescue
    _ -> :ok
  end

  def handle_event([:vor, :monitored, :resilience_fired], _measurements, meta, table) do
    inv = Map.get(meta, :invariant)
    agent = Map.get(meta, :agent)
    key = if Map.get(meta, :restores_target, true), do: :recovered, else: :unrecovered
    if inv, do: :ets.insert(table, {{key, inv, agent}})
    :ok
  rescue
    _ -> :ok
  end

  def handle_event(_event, _measurements, _meta, _table), do: :ok

  # Fold the observed rows into a per-invariant summary and a list of violations.
  defp build_report(rows) do
    deadlines = for {{:deadline, inv, agent}} <- rows, do: {inv, agent}
    recovered = for {{:recovered, inv, agent}} <- rows, do: {inv, agent}
    unrecovered = for {{:unrecovered, inv, agent}} <- rows, do: {inv, agent}

    invariants =
      (deadlines ++ recovered ++ unrecovered)
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()

    per_invariant =
      Enum.map(invariants, fn inv ->
        d = for {i, a} <- deadlines, i == inv, do: a
        u = for {i, a} <- unrecovered, i == inv, do: a

        %{
          invariant: inv,
          deadlines_exceeded: length(Enum.uniq(d)),
          agents_stuck: Enum.uniq(u),
          # A deadline that was exceeded and whose recovery did not restore a
          # good state is a monitored violation; otherwise it recovered.
          status: if(u != [], do: :violated, else: :recovered)
        }
      end)

    violations = for %{status: :violated, invariant: inv, agents_stuck: agents} <- per_invariant, do: {inv, agents}

    %{invariants: per_invariant, violations: violations}
  end
end
