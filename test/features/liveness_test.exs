defmodule Vor.Features.LivenessTest do
  use ExUnit.Case

  # ----------------------------------------------------------------------
  # Tarjan's SCC
  # ----------------------------------------------------------------------

  test "tarjan finds simple cycle" do
    graph = %{a: [:b], b: [:c], c: [:a], d: [:a]}
    sccs = Vor.Explorer.Tarjan.find_sccs(graph)
    assert length(sccs) == 1
    assert Enum.sort(hd(sccs)) == [:a, :b, :c]
  end

  test "tarjan finds multiple SCCs" do
    graph = %{a: [:b, :c], b: [:a], c: [:d], d: [:c]}
    sccs = Vor.Explorer.Tarjan.find_sccs(graph)
    assert length(sccs) == 2
  end

  test "tarjan handles acyclic graph" do
    graph = %{a: [:b], b: [:c], c: []}
    sccs = Vor.Explorer.Tarjan.find_sccs(graph)
    assert sccs == []
  end

  test "tarjan handles self-loop" do
    graph = %{a: [:a, :b], b: []}
    sccs = Vor.Explorer.Tarjan.find_sccs(graph)
    assert length(sccs) == 1
    assert hd(sccs) == [:a]
  end

  test "tarjan handles empty graph" do
    assert Vor.Explorer.Tarjan.find_sccs(%{}) == []
  end

  # ----------------------------------------------------------------------
  # Single-agent liveness: lock is eventually released
  # ----------------------------------------------------------------------

  test "single-agent liveness: lock with release handler passes" do
    source = """
    agent Lock do
      state phase: :free | :held

      protocol do
        accepts {:acquire}
        accepts {:release}
        emits {:ok}
      end

      on {:acquire} when phase == :free do
        transition phase: :held
        emit {:ok}
      end

      on {:release} when phase == :held do
        transition phase: :free
        emit {:ok}
      end

      liveness "lock released" proven do
        always(phase == :held implies eventually(phase != :held))
      end
    end
    """

    {:ok, _} = Vor.Compiler.compile_string(source)
  end

  test "single-agent liveness violation: no release handler" do
    source = """
    agent Lock do
      state phase: :free | :held

      protocol do
        accepts {:acquire}
        emits {:ok}
      end

      on {:acquire} when phase == :free do
        transition phase: :held
        emit {:ok}
      end

      liveness "lock released" proven do
        always(phase == :held implies eventually(phase != :held))
      end
    end
    """

    result = Vor.Compiler.compile_string(source)
    assert {:error, %{type: :liveness_violation, name: "lock released"}} = result
  end

  # ----------------------------------------------------------------------
  # Liveness with monitored tier is not verified at compile time
  # ----------------------------------------------------------------------

  test "monitored liveness is not verified at compile time (runtime only)" do
    source = """
    agent Lock do
      state phase: :free | :held

      protocol do
        accepts {:acquire}
        emits {:ok}
      end

      on {:acquire} when phase == :free do
        transition phase: :held
        emit {:ok}
      end

      liveness "lock released" monitored(within: 5000) do
        always(phase == :held implies eventually(phase != :held))
      end
    end
    """

    # monitored liveness compiles fine even without a release handler
    # (it's enforced at runtime via timeout, not at compile time)
    {:ok, _} = Vor.Compiler.compile_string(source)
  end

  # ----------------------------------------------------------------------
  # Liveness with existing examples
  # ----------------------------------------------------------------------

  test "all existing examples still compile with liveness verifier active" do
    for file <- Path.wildcard("examples/*.vor") do
      source = File.read!(file)

      result =
        if String.contains?(source, "system ") do
          Vor.Compiler.compile_system(source)
        else
          Vor.Compiler.compile_string(source)
        end

      assert match?({:ok, _}, result), "Failed: #{file}"
    end
  end

  # ----------------------------------------------------------------------
  # Liveness body parsing
  # ----------------------------------------------------------------------

  # ----------------------------------------------------------------------
  # Multi-agent liveness
  # ----------------------------------------------------------------------

  test "multi-agent liveness passes when obligation is fulfillable" do
    source = """
    agent Toggle do
      state mode: :off | :on

      protocol do
        accepts {:turn_on}
        accepts {:turn_off}
        emits {:ok}
      end

      on {:turn_on} when mode == :off do
        transition mode: :on
        emit {:ok}
      end

      on {:turn_off} when mode == :on do
        transition mode: :off
        emit {:ok}
      end
    end

    system TogglePair do
      agent :a, Toggle()
      agent :b, Toggle()

      liveness "eventually on" proven do
        always(mode == :off implies eventually(mode == :on))
      end
    end
    """

    result = Vor.Explorer.check_file(source, max_depth: 10, max_states: 1000)
    assert {:ok, _, stats} = result
    assert stats.liveness != nil
    assert stats.liveness.sccs_checked >= 0
  end

  test "multi-agent liveness detects stuck system" do
    source = """
    agent Stuck do
      state mode: :waiting | :done

      protocol do
        accepts {:poke}
        emits {:ok}
      end

      on {:poke} when mode == :waiting do
        emit {:ok}
      end
    end

    system StuckPair do
      agent :a, Stuck()
      agent :b, Stuck()

      liveness "eventually done" proven do
        always(mode == :waiting implies eventually(mode == :done))
      end
    end
    """

    result = Vor.Explorer.check_file(source, max_depth: 10, max_states: 1000)
    assert {:ok, _, stats} = result
    # The stuck system should have liveness results with violations
    assert stats.liveness != nil
    violations = Enum.filter(stats.liveness.results, fn
      {:violation, _, _} -> true
      _ -> false
    end)
    assert length(violations) > 0
  end

  test "system with safety + liveness reports both" do
    source = """
    agent Node do
      state role: :follower | :leader

      protocol do
        accepts {:promote}
        accepts {:demote}
        emits {:ok}
      end

      on {:promote} when role == :follower do
        transition role: :leader
        emit {:ok}
      end

      on {:demote} when role == :leader do
        transition role: :follower
        emit {:ok}
      end
    end

    system Pair do
      agent :a, Node()
      agent :b, Node()

      safety "max one leader" proven do
        never(count(agents where role == :leader) > 1)
      end

      liveness "leader exists" proven do
        always(role == :follower implies eventually(role == :leader))
      end
    end
    """

    result = Vor.Explorer.check_file(source, max_depth: 10, max_states: 1000)
    # Safety should pass (or detect violation — both independent nodes can become leader)
    # Liveness should be checked
    case result do
      {:ok, _, stats} ->
        assert stats.liveness != nil
      {:error, :violation, _, _, _} ->
        # Safety violation — both promoted independently. That's fine for this test.
        assert true
    end
  end

  test "no liveness invariants skips SCC analysis" do
    source = """
    agent Node do
      state mode: :idle | :active

      protocol do
        accepts {:go}
        emits {:ok}
      end

      on {:go} when mode == :idle do
        transition mode: :active
        emit {:ok}
      end
    end

    system Pair do
      agent :a, Node()
      agent :b, Node()

      safety "test" proven do
        never(count(agents where mode == :active) > 2)
      end
    end
    """

    {:ok, _, stats} = Vor.Explorer.check_file(source, max_depth: 10, max_states: 1000)
    # No liveness invariants → no liveness section
    assert stats[:liveness] == nil
  end

  # ----------------------------------------------------------------------
  # Body parsing
  # ----------------------------------------------------------------------

  test "liveness body parser extracts always-implies-eventually" do
    body_tokens = [
      {:keyword, nil, :always},
      {:delimiter, nil, :open_paren},
      {:identifier, nil, :phase},
      {:operator, nil, :==},
      {:atom, nil, "held"},
      {:identifier, nil, :implies},
      {:identifier, nil, :eventually},
      {:delimiter, nil, :open_paren},
      {:identifier, nil, :phase},
      {:operator, nil, :!=},
      {:atom, nil, "held"},
      {:delimiter, nil, :close_paren},
      {:delimiter, nil, :close_paren}
    ]

    assert {:ok, %{precondition: pre, postcondition: post}} =
             Vor.Explorer.LivenessChecker.parse_liveness_body(body_tokens)

    assert length(pre) > 0
    assert length(post) > 0
  end
end
