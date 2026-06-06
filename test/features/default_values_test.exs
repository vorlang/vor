defmodule Vor.Features.DefaultValuesTest do
  use ExUnit.Case

  alias Vor.AST

  defp parse(source) do
    {:ok, tokens} = Vor.Lexer.tokenize(source)
    Vor.Parser.parse(tokens)
  end

  defp protocol(ast) do
    Enum.find(ast.body, &match?(%AST.Protocol{}, &1))
  end

  # ----------------------------------------------------------------------
  # Positive — parsing `default:` on accepts fields
  # ----------------------------------------------------------------------

  test "parses field with integer default value" do
    source = """
    agent Worker do
      state mode: :idle

      protocol do
        accepts {:task, name: atom, priority: integer default: 5}
        emits {:ok}
      end

      on {:task, name: N, priority: P} do
        emit {:ok}
      end
    end
    """

    {:ok, ast} = parse(source)
    task = protocol(ast).accepts |> hd()

    # Field list is unchanged (still {name, type} tuples)
    assert task.fields == [{:name, :atom}, {:priority, :integer}]
    # Default captured separately, keyed by field name
    assert task.defaults == %{priority: 5}
  end

  test "parses multiple defaults and atom defaults" do
    source = """
    agent Worker do
      state mode: :idle

      protocol do
        accepts {:search, query: binary, limit: integer default: 10, mode: atom default: :fast}
        emits {:ok}
      end

      on {:search, query: Q, limit: L, mode: M} do
        emit {:ok}
      end
    end
    """

    {:ok, ast} = parse(source)
    search = protocol(ast).accepts |> hd()
    assert search.defaults == %{limit: 10, mode: :fast}
  end

  test "fields without defaults produce an empty defaults map" do
    source = """
    agent Worker do
      state mode: :idle

      protocol do
        accepts {:task, name: atom}
        emits {:ok}
      end

      on {:task, name: N} do
        emit {:ok}
      end
    end
    """

    {:ok, ast} = parse(source)
    assert (protocol(ast).accepts |> hd()).defaults == %{}
  end

  # ----------------------------------------------------------------------
  # Negative — defaults are only valid on accepts
  # ----------------------------------------------------------------------

  test "default not allowed on emits fields" do
    source = """
    agent Worker do
      state mode: :idle

      protocol do
        accepts {:task}
        emits {:done, count: integer default: 0}
      end

      on {:task} do
        emit {:done, count: 1}
      end
    end
    """

    assert {:error, _} = parse(source)
  end

  test "default not allowed on sends fields" do
    source = """
    agent Worker do
      state mode: :idle

      protocol do
        accepts {:task}
        sends {:ping, n: integer default: 0}
      end

      on {:task} do
        emit {:ok}
      end
    end
    """

    assert {:error, _} = parse(source)
  end

  # ----------------------------------------------------------------------
  # Runtime — defaults filled via maps:merge in compiled handlers
  # ----------------------------------------------------------------------

  test "default filled in at runtime (gen_server) and overridden when present" do
    source = """
    agent Worker do
      protocol do
        accepts {:task, name: atom, count: integer default: 1}
        emits {:done, name: atom, count: integer}
      end

      on {:task, name: N, count: C} do
        emit {:done, name: N, count: C}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])

    # Sender omits the defaulted field — default fills in
    assert {:done, %{name: :test, count: 1}} = GenServer.call(pid, {:task, %{name: :test}})

    # Sender includes the field — its value wins over the default
    assert {:done, %{name: :test, count: 10}} = GenServer.call(pid, {:task, %{name: :test, count: 10}})

    GenServer.stop(pid)
  end

  test "default filled in at runtime (gen_statem with state)" do
    source = """
    agent Worker do
      state phase: :ready | :done

      protocol do
        accepts {:task, name: atom, count: integer default: 7}
        emits {:done, name: atom, count: integer}
      end

      on {:task, name: N, count: C} when phase == :ready do
        emit {:done, name: N, count: C}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = :gen_statem.start_link(result.module, [], [])

    assert {:done, %{name: :a, count: 7}} = :gen_statem.call(pid, {:task, %{name: :a}})
    assert {:done, %{name: :a, count: 3}} = :gen_statem.call(pid, {:task, %{name: :a, count: 3}})

    :gen_statem.stop(pid)
  end

  # ----------------------------------------------------------------------
  # Compat integration — defaults make field additions compatible end-to-end
  # ----------------------------------------------------------------------

  defp write_vor(source) do
    path = Path.join(System.tmp_dir!(), "vor_defaults_#{:rand.uniform(1_000_000)}.vor")
    File.write!(path, source)
    path
  end

  test "adding a defaulted field reads as COMPATIBLE through the mix task" do
    old =
      write_vor("""
      agent Worker do
        protocol do
          accepts {:task, name: atom}
          emits {:ok}
        end
        on {:task, name: N} do
          emit {:ok}
        end
      end
      """)

    new =
      write_vor("""
      agent Worker do
        protocol do
          accepts {:task, name: atom, count: integer default: 1}
          emits {:ok}
        end
        on {:task, name: N, count: C} do
          emit {:ok}
        end
      end
      """)

    # Compatible change — the mix task must not raise.
    Mix.Tasks.Vor.Compat.run([new, "--against", old])

    File.rm(old)
    File.rm(new)
  end

  test "adding a non-defaulted field reads as INCOMPATIBLE through the mix task" do
    old =
      write_vor("""
      agent Worker do
        protocol do
          accepts {:task, name: atom}
          emits {:ok}
        end
        on {:task, name: N} do
          emit {:ok}
        end
      end
      """)

    new =
      write_vor("""
      agent Worker do
        protocol do
          accepts {:task, name: atom, count: integer}
          emits {:ok}
        end
        on {:task, name: N, count: C} do
          emit {:ok}
        end
      end
      """)

    assert_raise Mix.Error, fn ->
      Mix.Tasks.Vor.Compat.run([new, "--against", old])
    end

    File.rm(old)
    File.rm(new)
  end
end
