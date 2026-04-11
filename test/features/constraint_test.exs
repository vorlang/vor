defmodule Vor.Features.ConstraintTest do
  use ExUnit.Case

  test "protocol constraint parses and compiles" do
    source = """
    agent Service do
      protocol do
        accepts {:transfer, amount: integer} where amount > 0 and amount < 100000
        emits {:ok}
      end

      on {:transfer, amount: A} do
        emit {:ok}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_string(source)
    assert result.module
  end

  test "constraint rejects invalid input" do
    source = """
    agent Service do
      protocol do
        accepts {:transfer, amount: integer} where amount > 0
        emits {:ok, amount: integer}
      end

      on {:transfer, amount: A} do
        emit {:ok, amount: A}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])

    assert {:ok, %{amount: 50}} = GenServer.call(pid, {:transfer, %{amount: 50}})
    assert {:error, {:constraint_violated, :transfer, _}} = GenServer.call(pid, {:transfer, %{amount: -5}})
    assert {:error, {:constraint_violated, :transfer, _}} = GenServer.call(pid, {:transfer, %{amount: 0}})

    GenServer.stop(pid)
  end

  test "constraint allows boundary values" do
    source = """
    agent Service do
      protocol do
        accepts {:set, value: integer} where value >= 1 and value <= 100
        emits {:ok}
      end

      on {:set, value: V} do
        emit {:ok}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])

    assert {:ok, _} = GenServer.call(pid, {:set, %{value: 1}})
    assert {:ok, _} = GenServer.call(pid, {:set, %{value: 100}})
    assert {:error, {:constraint_violated, :set, _}} = GenServer.call(pid, {:set, %{value: 0}})
    assert {:error, {:constraint_violated, :set, _}} = GenServer.call(pid, {:set, %{value: 101}})

    GenServer.stop(pid)
  end

  test "constraint with cross-field comparison" do
    source = """
    agent Range do
      protocol do
        accepts {:set_range, min: integer, max: integer} where min >= 0 and max > min
        emits {:ok}
      end

      on {:set_range, min: Lo, max: Hi} do
        emit {:ok}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])

    assert {:ok, _} = GenServer.call(pid, {:set_range, %{min: 0, max: 10}})
    assert {:error, {:constraint_violated, :set_range, _}} = GenServer.call(pid, {:set_range, %{min: 10, max: 5}})
    assert {:error, {:constraint_violated, :set_range, _}} = GenServer.call(pid, {:set_range, %{min: -1, max: 10}})

    GenServer.stop(pid)
  end

  test "constraint with != operator" do
    source = """
    agent Service do
      protocol do
        accepts {:update, name: atom} where name != :nil
        emits {:ok}
      end

      on {:update, name: N} do
        emit {:ok}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])

    assert {:ok, _} = GenServer.call(pid, {:update, %{name: :alice}})
    assert {:error, {:constraint_violated, :update, _}} = GenServer.call(pid, {:update, %{name: :nil}})

    GenServer.stop(pid)
  end

  test "no constraint means all values accepted" do
    source = """
    agent Echo do
      protocol do
        accepts {:echo, value: integer}
        emits {:ok, value: integer}
      end

      on {:echo, value: V} do
        emit {:ok, value: V}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])

    assert {:ok, %{value: -999}} = GenServer.call(pid, {:echo, %{value: -999}})
    assert {:ok, %{value: 0}} = GenServer.call(pid, {:echo, %{value: 0}})

    GenServer.stop(pid)
  end

  test "constraint works with gen_statem handler guards" do
    source = """
    agent Gate do
      state phase: :open | :closed

      protocol do
        accepts {:enter, ticket: integer} where ticket > 0
        emits {:allowed, ticket: integer}
        emits {:denied}
      end

      on {:enter, ticket: T} when phase == :open do
        emit {:allowed, ticket: T}
      end

      on {:enter, ticket: T} when phase == :closed do
        emit {:denied}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = :gen_statem.start_link(result.module, [], [])

    assert {:allowed, %{ticket: 5}} = :gen_statem.call(pid, {:enter, %{ticket: 5}})
    assert {:error, {:constraint_violated, :enter, _}} = :gen_statem.call(pid, {:enter, %{ticket: -1}})

    :gen_statem.stop(pid)
  end

  test "constraint violation includes description string" do
    source = """
    agent Service do
      protocol do
        accepts {:transfer, amount: integer} where amount > 0
        emits {:ok}
      end

      on {:transfer, amount: A} do
        emit {:ok}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])

    {:error, {:constraint_violated, :transfer, desc}} = GenServer.call(pid, {:transfer, %{amount: -1}})
    assert is_binary(desc)
    assert desc =~ "amount"

    GenServer.stop(pid)
  end

  test "all existing examples still compile" do
    for file <- Path.wildcard("examples/*.vor") do
      source = File.read!(file)
      result = if String.contains?(source, "system ") do
        Vor.Compiler.compile_system(source)
      else
        Vor.Compiler.compile_string(source)
      end
      assert match?({:ok, _}, result), "#{file} failed"
    end
  end
end
