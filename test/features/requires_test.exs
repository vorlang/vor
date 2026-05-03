defmodule Vor.Features.RequiresTest do
  use ExUnit.Case

  @moduletag timeout: 30_000

  defp write_temp_vor(source) do
    path = Path.join(System.tmp_dir!(), "vor_req_test_#{:rand.uniform(100_000)}.vor")
    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)
    path
  end

  # ----------------------------------------------------------------------
  # Parser
  # ----------------------------------------------------------------------

  test "parses requires with OTP application atom" do
    source = """
    agent Simple do
      protocol do
        accepts {:ping}
        emits {:ok}
      end
      on {:ping} do
        emit {:ok}
      end
    end

    system Test do
      requires :myapp
      agent :a, Simple()
    end
    """

    {:ok, result} = Vor.Compiler.compile_system(source)
    assert length(result.system_ir.requires) == 1
    assert hd(result.system_ir.requires).type == :application
    assert hd(result.system_ir.requires).target == :myapp
  end

  test "parses requires with module name" do
    source = """
    agent Simple do
      protocol do
        accepts {:ping}
        emits {:ok}
      end
      on {:ping} do
        emit {:ok}
      end
    end

    system Test do
      requires Elixir.SomeModule
      agent :a, Simple()
    end
    """

    {:ok, result} = Vor.Compiler.compile_system(source)
    assert length(result.system_ir.requires) == 1
    req = hd(result.system_ir.requires)
    assert req.type == :module
  end

  test "parses multiple requires in declaration order" do
    source = """
    agent Simple do
      protocol do
        accepts {:ping}
        emits {:ok}
      end
      on {:ping} do
        emit {:ok}
      end
    end

    system Test do
      requires :app1
      requires :app2

      agent :a, Simple()
    end
    """

    {:ok, result} = Vor.Compiler.compile_system(source)
    assert length(result.system_ir.requires) == 2
    targets = Enum.map(result.system_ir.requires, & &1.target)
    assert targets == [:app1, :app2]
  end

  test "system without requires has empty list" do
    source = """
    agent Simple do
      protocol do
        accepts {:ping}
        emits {:ok}
      end
      on {:ping} do
        emit {:ok}
      end
    end

    system Test do
      agent :a, Simple()
    end
    """

    {:ok, result} = Vor.Compiler.compile_system(source)
    assert result.system_ir.requires == []
  end

  # ----------------------------------------------------------------------
  # Model checker ignores requires
  # ----------------------------------------------------------------------

  test "model checker works with requires referencing nonexistent module" do
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

    system Test do
      requires NonExistentModule

      agent :a, Node()
      agent :b, Node()

      safety "test" proven do
        never(count(agents where mode == :active) > 2)
      end
    end
    """

    # mix vor.check doesn't start real processes — requires is irrelevant
    {:ok, :proven, _} = Vor.Explorer.check_file(source, max_depth: 10, max_states: 1000)
  end

  # ----------------------------------------------------------------------
  # Simulator with requires
  # ----------------------------------------------------------------------

  test "simulator handles nonexistent module dependency gracefully" do
    source = """
    agent Simple do
      protocol do
        accepts {:ping}
        emits {:ok}
      end
      on {:ping} do
        emit {:ok}
      end
    end

    system Test do
      requires NonExistentModule99

      agent :a, Simple()

      safety "test" proven do
        never(count(agents where mode == :error) > 0)
      end
    end
    """

    path = write_temp_vor(source)
    config = %{duration_ms: 2000, seed: 42, inject_faults: false,
      check_interval_ms: 500, verbose: false}

    result = Vor.Simulator.run_file(path, config)
    assert match?({:error, :dependency_failed, _, _}, result)
  end

  test "all existing examples compile with requires support" do
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
end
