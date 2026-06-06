defmodule Vor.Features.SurfaceTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  defp surface(source) do
    {:ok, map} = Vor.Surface.extract_source(source, "test.vor")
    map
  end

  defp first_agent(source), do: surface(source).agents |> hd()
  defp first_system(source), do: surface(source).systems |> hd()

  # ----------------------------------------------------------------------
  # Agents, states, protocol
  # ----------------------------------------------------------------------

  test "surfaces agent name, behaviour, params, and states" do
    a =
      first_agent("""
      agent LockManager(timeout: integer) do
        state phase: :free | :held
        state holder: atom

        protocol do
          accepts {:acquire, client: atom}
          emits {:grant, client: atom}
        end
      end
      """)

    assert a.name == "LockManager"
    assert a.type == "gen_statem"
    assert a.params == ["timeout: integer"]

    assert %{name: "phase", type: "enum", values: ["free", "held"]} in a.states
    assert %{name: "holder", type: "atom"} in a.states

    assert [accept] = a.protocol.accepts
    assert accept.tag == "acquire"
    assert accept.fields == %{"client" => "atom"}
    assert [%{tag: "grant", fields: %{"client" => "atom"}}] = a.protocol.emits
  end

  test "agent without an enum state field is a gen_server" do
    a =
      first_agent("""
      agent Counter do
        state count: integer
        protocol do
          accepts {:inc}
          emits {:ok}
        end
      end
      """)

    assert a.type == "gen_server"
    assert %{name: "count", type: "integer"} in a.states
  end

  # ----------------------------------------------------------------------
  # Safety + liveness invariants
  # ----------------------------------------------------------------------

  test "surfaces a safety invariant with kind, tier, body, and line" do
    a =
      first_agent("""
      agent Guard do
        state phase: :open | :closed
        protocol do
          accepts {:go}
          emits {:ok}
        end

        safety "no grant when held" proven do
          never(phase == :open and emitted({:grant, _}))
        end
      end
      """)

    inv = Enum.find(a.invariants, &(&1.kind == "safety"))
    assert inv.name == "no grant when held"
    assert inv.tier == "proven"
    assert inv.body == "never(phase == :open and emitted({:grant, _}))"
    assert is_integer(inv.line)
  end

  test "surfaces liveness invariants (proven and monitored)" do
    a =
      first_agent("""
      agent Worker(timeout: integer) do
        state phase: :busy | :idle
        protocol do
          accepts {:go}
          emits {:ok}
        end

        liveness "settles" proven do
          always(phase == :busy implies eventually(phase == :idle))
        end

        liveness "settles within bound" monitored(within: timeout) do
          always(phase == :busy implies eventually(phase == :idle))
        end
      end
      """)

    liveness = Enum.filter(a.invariants, &(&1.kind == "liveness"))
    assert length(liveness) == 2

    proven = Enum.find(liveness, &(&1.tier == "proven"))
    assert proven.name == "settles"
    refute Map.has_key?(proven, :within)

    monitored = Enum.find(liveness, &(&1.tier == "monitored"))
    assert monitored.within == "timeout"
    assert monitored.body =~ "eventually"
  end

  # ----------------------------------------------------------------------
  # Sensitive fields, where constraints, defaults
  # ----------------------------------------------------------------------

  test "surfaces sensitive state fields" do
    a =
      first_agent("""
      agent Vault do
        state phase: :locked | :open
        state secret: binary sensitive
        protocol do
          accepts {:open}
          emits {:ok}
        end
      end
      """)

    secret = Enum.find(a.states, &(&1.name == "secret"))
    assert secret.sensitive == true
  end

  test "surfaces where constraints on accepts" do
    a =
      first_agent("""
      agent Bank do
        state phase: :a | :b
        protocol do
          accepts {:transfer, amount: integer} where amount > 0 and amount < 100
          emits {:ok}
        end
      end
      """)

    [accept] = a.protocol.accepts
    assert accept.where == "amount > 0 and amount < 100"
  end

  test "surfaces default values on accepts fields" do
    a =
      first_agent("""
      agent Worker do
        state phase: :a | :b
        protocol do
          accepts {:task, name: atom, count: integer default: 1}
          emits {:ok}
        end
      end
      """)

    [accept] = a.protocol.accepts
    assert accept.defaults == %{"count" => 1}
  end

  # ----------------------------------------------------------------------
  # Backpressure + externs
  # ----------------------------------------------------------------------

  test "surfaces backpressure (agent-level max_queue, per-message limits and priority)" do
    a =
      first_agent("""
      agent Server do
        max_queue 500
        state phase: :a | :b
        protocol do
          accepts {:task} max_queue: 100
          accepts {:health} priority: true
          emits {:ok}
        end
      end
      """)

    assert a.backpressure == %{max_queue: 500}

    task = Enum.find(a.protocol.accepts, &(&1.tag == "task"))
    assert task.max_queue == 100

    health = Enum.find(a.protocol.accepts, &(&1.tag == "health"))
    assert health.priority == true
  end

  test "surfaces extern declarations" do
    a =
      first_agent("""
      agent Bridge do
        extern do
          Erlang.erlang.system_time(unit: atom) :: integer
        end

        protocol do
          accepts {:now}
          emits {:result, ts: integer}
        end
      end
      """)

    assert [extern] = a.externs
    assert extern.function == "system_time"
    assert extern.args == %{"unit" => "atom"}
    assert extern.return_type == "integer"
  end

  # ----------------------------------------------------------------------
  # Systems: instances, connections, requires, system invariants, chaos
  # ----------------------------------------------------------------------

  test "surfaces a system with instances, connections, requires, invariant, and chaos" do
    s =
      first_system("""
      agent Worker do
        state phase: :busy | :idle
        protocol do
          accepts {:go}
          emits {:ok}
        end
      end

      system Cluster do
        requires :my_app

        agent :a, Worker()
        agent :b, Worker()

        connect :a -> :b

        safety "bounded" proven do
          never(count(agents where phase == :busy) > 1)
        end

        chaos do
          duration 30s
          seed 42
          kill every: 5..15s
          partition duration: 2..8s
          workload rate: 5
          check every: 1s
        end
      end
      """)

    assert s.name == "Cluster"
    assert %{instance: "a", type: "Worker", params: %{}} in s.agents
    assert ["a", "b"] in s.connections
    assert [%{target: "my_app"}] = s.requires

    assert [inv] = s.invariants
    assert inv.kind == "safety"
    assert inv.name == "bounded"

    assert s.chaos[:duration_ms] == 30_000
    assert s.chaos[:seed] == 42
    # range tuples are coerced to JSON-safe lists
    assert s.chaos[:kill] == %{every: [5_000, 15_000]}
    assert s.chaos[:workload] == %{rate: 5}
  end

  # ----------------------------------------------------------------------
  # Output formats + mix task
  # ----------------------------------------------------------------------

  test "extracted surface is valid JSON for every example file" do
    Path.wildcard("examples/**/*.vor")
    |> Enum.each(fn path ->
      {:ok, map} = Vor.Surface.extract_source(File.read!(path), path)
      json = Jason.encode!(map)
      # round-trips cleanly
      assert is_map(Jason.decode!(json))
    end)
  end

  test "mix vor.surface --file emits valid JSON to stdout" do
    source = """
    agent Solo do
      state phase: :a | :b
      protocol do
        accepts {:go}
        emits {:ok}
      end
    end
    """

    path = Path.join(System.tmp_dir!(), "vor_surface_#{:rand.uniform(1_000_000)}.vor")
    File.write!(path, source)

    output = capture_io(fn -> Mix.Tasks.Vor.Surface.run(["--file", path]) end)

    decoded = Jason.decode!(output)
    assert decoded["project"] == "vor"
    assert [file] = decoded["files"]
    assert [agent] = file["agents"]
    assert agent["name"] == "Solo"

    File.rm(path)
  end

  test "mix vor.surface --format text produces readable output" do
    source = """
    agent Solo do
      state phase: :a | :b
      protocol do
        accepts {:go}
        emits {:ok}
      end
    end
    """

    path = Path.join(System.tmp_dir!(), "vor_surface_#{:rand.uniform(1_000_000)}.vor")
    File.write!(path, source)

    output = capture_io(fn -> Mix.Tasks.Vor.Surface.run(["--file", path, "--format", "text"]) end)

    assert output =~ "agent Solo (gen_statem)"
    assert output =~ "accepts: {:go}"

    File.rm(path)
  end
end
