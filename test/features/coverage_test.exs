defmodule Vor.Features.CoverageTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  # Coverage consumes Vor.Surface output: a list of %{file, agents, systems}
  # maps with string kind/tier values. These helpers build minimal maps in
  # that shape.

  defp agent(attrs) do
    Map.merge(
      %{name: "A", invariants: [], protocol: %{accepts: [], emits: []},
        backpressure: nil, externs: [], states: []},
      attrs
    )
  end

  defp system(attrs) do
    Map.merge(
      %{name: "S", invariants: [], agents: [], connections: [], requires: [], chaos: nil},
      attrs
    )
  end

  defp file(agents, systems), do: [%{file: "t.vor", agents: agents, systems: systems}]

  # ----------------------------------------------------------------------
  # Metric counting
  # ----------------------------------------------------------------------

  test "counts agents with safety invariants" do
    surface =
      file(
        [
          agent(%{name: "A", invariants: [%{kind: "safety", tier: "proven"}]}),
          agent(%{name: "B", invariants: []})
        ],
        []
      )

    cov = Vor.Coverage.analyze(surface)
    assert cov.agent_count == 2
    assert cov.agents_with_safety == 1
  end

  test "counts invariants by tier (across agents and systems)" do
    surface =
      file(
        [
          agent(%{
            invariants: [
              %{kind: "safety", tier: "proven"},
              %{kind: "liveness", tier: "monitored"},
              %{kind: "safety", tier: "proven"}
            ]
          })
        ],
        []
      )

    cov = Vor.Coverage.analyze(surface)
    assert cov.proven_count == 2
    assert cov.monitored_count == 1
  end

  test "counts protocol metrics" do
    surface =
      file(
        [
          agent(%{
            protocol: %{
              accepts: [
                %{tag: "order", where: "amount > 0", max_queue: 100, defaults: %{}},
                %{tag: "cancel", where: nil, max_queue: nil, defaults: %{}},
                %{tag: "update", where: nil, max_queue: nil, defaults: %{"priority" => 5}}
              ],
              emits: []
            }
          })
        ],
        []
      )

    cov = Vor.Coverage.analyze(surface)
    assert cov.total_accepts == 3
    assert cov.accepts_with_where == 1
    assert cov.accepts_with_max_queue == 1
    assert cov.accepts_with_defaults == 1
  end

  test "detects fully native agents" do
    surface =
      file(
        [
          agent(%{name: "Native", externs: []}),
          agent(%{name: "WithExtern", externs: [%{module: "gleam/payments", function: "charge"}]})
        ],
        []
      )

    cov = Vor.Coverage.analyze(surface)
    assert cov.agents_fully_native == 1
  end

  test "counts backpressure from agent-level and per-message limits" do
    surface =
      file(
        [
          agent(%{name: "AgentLevel", backpressure: %{max_queue: 500}}),
          agent(%{
            name: "PerMessage",
            protocol: %{accepts: [%{tag: "t", where: nil, max_queue: 50, defaults: %{}}], emits: []}
          }),
          agent(%{name: "None"})
        ],
        []
      )

    cov = Vor.Coverage.analyze(surface)
    assert cov.agents_with_backpressure == 2
  end

  test "counts sensitive fields" do
    surface =
      file(
        [
          agent(%{name: "Vault", states: [%{name: "secret", type: "binary", sensitive: true}]}),
          agent(%{name: "Plain", states: [%{name: "x", type: "integer"}]})
        ],
        []
      )

    cov = Vor.Coverage.analyze(surface)
    assert cov.agents_with_sensitive == 1
  end

  # ----------------------------------------------------------------------
  # Gap detection
  # ----------------------------------------------------------------------

  test "identifies an agent missing a safety invariant" do
    surface = file([agent(%{name: "NoSafety"})], [])
    cov = Vor.Coverage.analyze(surface)

    assert Enum.any?(cov.gaps, &(&1[:agent] == "NoSafety" and &1.missing == :safety_invariant))
  end

  test "detects system gaps (missing chaos block)" do
    surface =
      file([], [system(%{name: "Cluster", invariants: [%{kind: "safety", tier: "proven"}]})])

    cov = Vor.Coverage.analyze(surface)
    assert Enum.any?(cov.gaps, &(&1[:system] == "Cluster" and &1.missing == :chaos_block))
  end

  test "system requires gap only when its agents use externs" do
    agents = [
      agent(%{name: "Worker", externs: [%{module: "gleam/x", function: "f"}]})
    ]

    with_externs =
      file(agents, [system(%{name: "UsesExterns", agents: [%{instance: "w", type: "Worker"}], requires: []})])

    without =
      file([agent(%{name: "Pure", externs: []})],
        [system(%{name: "Pure", agents: [%{instance: "p", type: "Pure"}], requires: []})])

    assert Enum.any?(Vor.Coverage.analyze(with_externs).gaps, &(&1.missing == :requires))
    refute Enum.any?(Vor.Coverage.analyze(without).gaps, &(&1.missing == :requires))
  end

  # ----------------------------------------------------------------------
  # Output formats
  # ----------------------------------------------------------------------

  test "text format renders ratios" do
    cov = %Vor.Coverage{agent_count: 5, agents_with_safety: 3}
    text = Vor.Coverage.format_text(cov)
    assert text =~ "3 / 5"
    assert text =~ "Vor coverage for vor"
  end

  test "json format is valid and carries scores" do
    cov = %Vor.Coverage{
      agent_count: 5,
      agents_with_safety: 3,
      total_accepts: 12,
      accepts_with_where: 4
    }

    json = Vor.Coverage.format_json(cov)
    assert {:ok, decoded} = Jason.decode(json)
    assert decoded["agents"]["with_safety"] == 3
    assert decoded["score"]["agents_verified_pct"] == 60
    assert decoded["score"]["protocols_constrained_pct"] == 33
  end

  test "json gaps serialize with string missing reasons" do
    surface = file([agent(%{name: "NoSafety"})], [])
    cov = Vor.Coverage.analyze(surface)
    decoded = Jason.decode!(Vor.Coverage.format_json(cov))

    assert Enum.any?(decoded["gaps"], &(&1["agent"] == "NoSafety" and &1["missing"] == "safety_invariant"))
  end

  # ----------------------------------------------------------------------
  # End-to-end against real source / mix task
  # ----------------------------------------------------------------------

  test "analyzes real surface output from a .vor source" do
    source = """
    agent Guarded do
      state phase: :a | :b
      protocol do
        accepts {:go, n: integer} where n > 0
        emits {:ok}
      end
      safety "ok" proven do
        never(phase == :a and emitted({:bad, _}))
      end
    end
    """

    {:ok, surface} = Vor.Surface.extract_source(source, "guarded.vor")
    cov = Vor.Coverage.analyze([surface])

    assert cov.agent_count == 1
    assert cov.agents_with_safety == 1
    assert cov.agents_with_where == 1
    assert cov.accepts_with_where == 1
    assert cov.proven_count == 1
    refute Enum.any?(cov.gaps, &(&1.missing == :safety_invariant))
  end

  test "mix vor.coverage runs against examples and prints a report" do
    output = capture_io(fn -> Mix.Tasks.Vor.Coverage.run([]) end)
    assert output =~ "Vor coverage for vor"
    assert output =~ "Agents:"
    assert output =~ "Protocol coverage:"
  end

  test "mix vor.coverage --format json emits valid JSON" do
    output = capture_io(fn -> Mix.Tasks.Vor.Coverage.run(["--format", "json"]) end)
    assert {:ok, decoded} = Jason.decode(output)
    assert is_integer(decoded["agents"]["total"])
  end
end
