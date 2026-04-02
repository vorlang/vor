defmodule Vor.Analysis.CoverageTest do
  use ExUnit.Case

  test "missing handler for accepts produces compile error" do
    source = """
    agent MissingHandler do
      protocol do
        accepts {:request, value: integer}
        accepts {:control, command: atom}
        emits {:ok}
      end

      on {:request, value: V} do
        emit {:ok}
      end
    end
    """

    assert {:error, %{type: :missing_handler}} = Vor.Compiler.compile_string(source)
  end

  test "all accepts have handlers compiles" do
    source = """
    agent FullCoverage do
      protocol do
        accepts {:request, value: integer}
        accepts {:control, command: atom}
        emits {:ok}
      end

      on {:request, value: V} do
        emit {:ok}
      end

      on {:control, command: C} do
        emit {:ok}
      end
    end
    """

    {:ok, _mod} = Vor.Compiler.compile_string(source)
  end

  test "guarded handler counts as coverage for that tag" do
    source = """
    agent GuardedCoverage do
      state phase: :idle | :active

      protocol do
        accepts {:request, value: integer}
        emits {:ok}
        emits {:rejected}
      end

      on {:request, value: V} when phase == :idle do
        emit {:ok}
      end

      on {:request, value: V} when phase == :active do
        emit {:rejected}
      end
    end
    """

    {:ok, _mod} = Vor.Compiler.compile_string(source)
  end

  test "sends declarations don't require handlers" do
    source = """
    agent SenderOnly do
      protocol do
        accepts {:go}
        emits {:ok}
      end

      on {:go} do
        emit {:ok}
      end
    end
    """

    {:ok, _mod} = Vor.Compiler.compile_string(source)
  end
end
