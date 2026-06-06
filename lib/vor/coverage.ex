defmodule Vor.Coverage do
  @moduledoc """
  Aggregates the spec inventory produced by `Vor.Surface` into a project-level
  verification posture: how much of the declared surface is defended (safety,
  liveness, constraints, backpressure, chaos) and where the gaps are.

  `analyze/1` consumes a list of per-file maps in `Vor.Surface` shape
  (`%{file, agents, systems}`) and returns a `%Vor.Coverage{}` struct.
  `format_text/2` and `format_json/1` render it. This is purely a reader — it
  runs no verification.
  """

  defstruct agent_count: 0,
            agents_with_safety: 0,
            agents_with_liveness: 0,
            agents_with_where: 0,
            agents_with_backpressure: 0,
            agents_with_sensitive: 0,
            agents_fully_native: 0,
            system_count: 0,
            systems_with_safety: 0,
            systems_with_liveness: 0,
            systems_with_chaos: 0,
            systems_with_requires: 0,
            proven_count: 0,
            monitored_count: 0,
            bounded_verified: [],
            total_accepts: 0,
            accepts_with_where: 0,
            accepts_with_max_queue: 0,
            accepts_with_defaults: 0,
            gaps: []

  @doc "Analyze a list of `Vor.Surface` file maps into a coverage struct."
  def analyze(files) when is_list(files) do
    agents = Enum.flat_map(files, &Map.get(&1, :agents, []))
    systems = Enum.flat_map(files, &Map.get(&1, :systems, []))
    all_accepts = Enum.flat_map(agents, &accepts/1)

    %__MODULE__{
      agent_count: length(agents),
      agents_with_safety: Enum.count(agents, &has_kind?(&1, "safety")),
      agents_with_liveness: Enum.count(agents, &has_kind?(&1, "liveness")),
      agents_with_where: Enum.count(agents, &agent_has_where?/1),
      agents_with_backpressure: Enum.count(agents, &agent_has_backpressure?/1),
      agents_with_sensitive: Enum.count(agents, &agent_has_sensitive?/1),
      agents_fully_native: Enum.count(agents, &(externs(&1) == [])),
      system_count: length(systems),
      systems_with_safety: Enum.count(systems, &has_kind?(&1, "safety")),
      systems_with_liveness: Enum.count(systems, &has_kind?(&1, "liveness")),
      systems_with_chaos: Enum.count(systems, &(Map.get(&1, :chaos) != nil)),
      systems_with_requires: Enum.count(systems, &(requires(&1) != [])),
      proven_count: count_tier(agents ++ systems, "proven"),
      monitored_count: count_tier(agents ++ systems, "monitored"),
      bounded_verified: [],
      total_accepts: length(all_accepts),
      accepts_with_where: Enum.count(all_accepts, &(Map.get(&1, :where) != nil)),
      accepts_with_max_queue: Enum.count(all_accepts, &(Map.get(&1, :max_queue) != nil)),
      accepts_with_defaults: Enum.count(all_accepts, &(Map.get(&1, :defaults, %{}) != %{})),
      gaps: detect_gaps(agents, systems)
    }
  end

  # ---------------------------------------------------------------------------
  # Metric helpers — tolerant of atom or string kind/tier values
  # ---------------------------------------------------------------------------

  defp invariants(x), do: Map.get(x, :invariants, []) || []
  defp externs(a), do: Map.get(a, :externs, []) || []
  defp requires(s), do: Map.get(s, :requires, []) || []

  defp accepts(a) do
    case Map.get(a, :protocol) do
      %{accepts: acc} -> acc || []
      _ -> []
    end
  end

  defp has_kind?(x, kind) do
    Enum.any?(invariants(x), &(to_string(Map.get(&1, :kind)) == kind))
  end

  defp agent_has_where?(a), do: Enum.any?(accepts(a), &(Map.get(&1, :where) != nil))

  defp agent_has_backpressure?(a) do
    Map.get(a, :backpressure) != nil or
      Enum.any?(accepts(a), &(Map.get(&1, :max_queue) != nil))
  end

  defp agent_has_sensitive?(a) do
    a |> Map.get(:states, []) |> Enum.any?(&(Map.get(&1, :sensitive) == true))
  end

  defp count_tier(nodes, tier) do
    nodes
    |> Enum.flat_map(&invariants/1)
    |> Enum.count(&(to_string(Map.get(&1, :tier)) == tier))
  end

  # ---------------------------------------------------------------------------
  # Gap detection
  # ---------------------------------------------------------------------------

  defp detect_gaps(agents, systems) do
    externs_by_name = Map.new(agents, &{Map.get(&1, :name), externs(&1) != []})

    Enum.flat_map(agents, &agent_gaps/1) ++
      Enum.flat_map(systems, &system_gaps(&1, externs_by_name))
  end

  defp agent_gaps(a) do
    name = Map.get(a, :name)

    []
    |> add_gap(not has_kind?(a, "safety"), %{agent: name, missing: :safety_invariant})
    |> add_gap(not has_kind?(a, "liveness"), %{agent: name, missing: :liveness_invariant})
    |> add_gap(accepts(a) != [] and not agent_has_where?(a), %{agent: name, missing: :where_constraint})
  end

  defp system_gaps(s, externs_by_name) do
    name = Map.get(s, :name)
    needs_requires = system_needs_requires?(s, externs_by_name) and requires(s) == []

    []
    |> add_gap(not has_kind?(s, "safety"), %{system: name, missing: :safety_invariant})
    |> add_gap(not has_kind?(s, "liveness"), %{system: name, missing: :liveness_invariant})
    |> add_gap(Map.get(s, :chaos) == nil, %{system: name, missing: :chaos_block})
    |> add_gap(needs_requires, %{system: name, missing: :requires})
  end

  defp system_needs_requires?(s, externs_by_name) do
    s
    |> Map.get(:agents, [])
    |> Enum.any?(&Map.get(externs_by_name, Map.get(&1, :type), false))
  end

  defp add_gap(gaps, true, gap), do: gaps ++ [gap]
  defp add_gap(gaps, false, _gap), do: gaps

  # ---------------------------------------------------------------------------
  # Formatting
  # ---------------------------------------------------------------------------

  @doc "Render the coverage struct as a human-readable report."
  def format_text(%__MODULE__{} = c, project \\ "vor") do
    [
      "Vor coverage for #{project}",
      "====================",
      "",
      "Agents:                     #{c.agent_count}",
      ratio_line("with safety invariants:", c.agents_with_safety, c.agent_count),
      ratio_line("with liveness invariants:", c.agents_with_liveness, c.agent_count),
      ratio_line("with where constraints:", c.agents_with_where, c.agent_count),
      ratio_line("with backpressure:", c.agents_with_backpressure, c.agent_count),
      ratio_line("with sensitive fields:", c.agents_with_sensitive, c.agent_count),
      ratio_line("fully native (0 externs):", c.agents_fully_native, c.agent_count),
      "",
      "Systems:                    #{c.system_count}",
      ratio_line("with safety invariants:", c.systems_with_safety, c.system_count),
      ratio_line("with liveness invariants:", c.systems_with_liveness, c.system_count),
      ratio_line("with chaos block:", c.systems_with_chaos, c.system_count),
      ratio_line("with requires:", c.systems_with_requires, c.system_count),
      "",
      "Invariant breakdown:",
      "  proven (compile-time):    #{c.proven_count}",
      "  monitored (runtime):      #{c.monitored_count}",
      "",
      "Protocol coverage:",
      "  total accepts:            #{c.total_accepts}",
      count_pct_line("with where constraints:", c.accepts_with_where, c.total_accepts),
      count_pct_line("with max_queue:", c.accepts_with_max_queue, c.total_accepts),
      count_pct_line("with defaults:", c.accepts_with_defaults, c.total_accepts),
      "",
      "Gaps:"
    ]
    |> Kernel.++(format_gaps(c.gaps))
    |> Enum.join("\n")
  end

  defp format_gaps([]), do: ["  none — every agent and system has its baseline defenses"]

  defp format_gaps(gaps) do
    Enum.map(gaps, fn gap ->
      {subject, name} =
        case gap do
          %{agent: a} -> {"agent", a}
          %{system: s} -> {"system", s}
        end

      "  #{String.pad_trailing("#{subject} #{name}", 22)} — #{gap_text(gap.missing)}"
    end)
  end

  defp gap_text(:safety_invariant), do: "no safety invariants"
  defp gap_text(:liveness_invariant), do: "no liveness invariants"
  defp gap_text(:where_constraint), do: "no where constraints on any accepts"
  defp gap_text(:chaos_block), do: "no chaos block"
  defp gap_text(:requires), do: "no requires declared (agents use externs)"
  defp gap_text(other), do: to_string(other)

  @doc "Render the coverage struct as JSON for CI/tooling consumption."
  def format_json(%__MODULE__{} = c) do
    Jason.encode!(to_json_map(c), pretty: true)
  end

  defp to_json_map(%__MODULE__{} = c) do
    %{
      agents: %{
        total: c.agent_count,
        with_safety: c.agents_with_safety,
        with_liveness: c.agents_with_liveness,
        with_where: c.agents_with_where,
        with_backpressure: c.agents_with_backpressure,
        with_sensitive: c.agents_with_sensitive,
        fully_native: c.agents_fully_native
      },
      systems: %{
        total: c.system_count,
        with_safety: c.systems_with_safety,
        with_liveness: c.systems_with_liveness,
        with_chaos: c.systems_with_chaos,
        with_requires: c.systems_with_requires
      },
      invariants: %{
        proven: c.proven_count,
        monitored: c.monitored_count,
        bounded_verified: c.bounded_verified
      },
      protocol: %{
        total_accepts: c.total_accepts,
        with_where: c.accepts_with_where,
        with_max_queue: c.accepts_with_max_queue,
        with_defaults: c.accepts_with_defaults
      },
      gaps: Enum.map(c.gaps, &gap_json/1),
      score: %{
        agents_verified_pct: pct(c.agents_with_safety, c.agent_count),
        protocols_constrained_pct: pct(c.accepts_with_where, c.total_accepts)
      }
    }
  end

  defp gap_json(%{agent: a, missing: m}), do: %{agent: a, missing: to_string(m)}
  defp gap_json(%{system: s, missing: m}), do: %{system: s, missing: to_string(m)}

  # ---------------------------------------------------------------------------
  # Formatting helpers
  # ---------------------------------------------------------------------------

  defp ratio_line(label, n, total) do
    "  #{String.pad_trailing(label, 26)}#{n} / #{total}  (#{pct(n, total)}%)"
  end

  defp count_pct_line(label, n, total) do
    "  #{String.pad_trailing(label, 24)}#{n}  (#{pct(n, total)}%)"
  end

  defp pct(_n, 0), do: 0
  defp pct(n, total), do: round(n * 100 / total)
end
