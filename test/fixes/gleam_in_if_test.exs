defmodule Vor.Fixes.GleamInIfTest do
  use ExUnit.Case

  test "gleam extern call with binding inside if block" do
    source = """
    agent GleamInIf do
      extern gleam do
        my/helpers.transform(value: integer) :: integer
      end

      state count: integer

      protocol do
        accepts {:process, value: integer}
        emits {:result, value: integer}
        emits {:skipped}
      end

      on {:process, value: V} do
        if V > 0 do
          result = my/helpers.transform(value: V)
          emit {:result, value: result}
        else
          emit {:skipped}
        end
      end
    end
    """

    {:ok, _} = Vor.Compiler.compile_string(source)
  end

  test "gleam extern call in else branch" do
    source = """
    agent GleamInElse do
      extern gleam do
        my/module.default_value() :: integer
      end

      state data: map

      protocol do
        accepts {:get, key: atom}
        emits {:value, result: integer}
      end

      on {:get, key: K} do
        has_key = map_has(data, K)
        if has_key == :true do
          v = map_get(data, K, 0)
          emit {:value, result: v}
        else
          default = my/module.default_value()
          emit {:value, result: default}
        end
      end
    end
    """

    {:ok, _} = Vor.Compiler.compile_string(source)
  end

  test "deep gleam module path in if block" do
    source = """
    agent DeepPathIf do
      extern gleam do
        vordb/storage/rocks.get(key: binary) :: term
      end

      state data: map

      protocol do
        accepts {:load, key: binary}
        emits {:loaded, value: term}
        emits {:empty}
      end

      on {:load, key: K} do
        has_key = map_has(data, K)
        if has_key == :true do
          emit {:loaded, value: map_get(data, K, :none)}
        else
          persisted = vordb/storage/rocks.get(key: K)
          emit {:loaded, value: persisted}
        end
      end
    end
    """

    {:ok, _} = Vor.Compiler.compile_string(source)
  end

  test "gleam extern without binding in if block" do
    source = """
    agent GleamNoBind do
      extern gleam do
        my/module.side_effect(value: integer) :: term
      end

      state count: integer

      protocol do
        accepts {:go, value: integer}
        emits {:done}
        emits {:skipped}
      end

      on {:go, value: V} do
        if V > 0 do
          my/module.side_effect(value: V)
          emit {:done}
        else
          emit {:skipped}
        end
      end
    end
    """

    {:ok, _} = Vor.Compiler.compile_string(source)
  end

  test "existing erlang extern in if block still works" do
    source = """
    agent ErlangInIfCompat do
      extern do
        Erlang.erlang.system_time(unit: atom) :: integer
      end

      protocol do
        accepts {:check, value: integer}
        emits {:result, timestamp: integer}
        emits {:skipped}
      end

      on {:check, value: V} do
        if V > 0 do
          ts = Erlang.erlang.system_time(unit: :millisecond)
          emit {:result, timestamp: ts}
        else
          emit {:skipped}
        end
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    {:result, %{timestamp: ts}} = GenServer.call(pid, {:check, %{value: 1}})
    assert is_integer(ts)
    GenServer.stop(pid)
  end
end
