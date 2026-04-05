defmodule Vor.Features.TypeTrackingTest do
  use ExUnit.Case

  # --- Error: guaranteed crashes ---

  test "error: arithmetic on map state field" do
    source = """
    agent TypeErr1 do
      state store: map
      protocol do
        accepts {:bad}
        emits {:result, value: integer}
      end
      on {:bad} do
        x = store + 1
        emit {:result, value: x}
      end
    end
    """
    assert {:error, %{type: :type_error}} = Vor.Compiler.compile_string(source)
  end

  test "error: map_get on integer state field" do
    source = """
    agent TypeErr2 do
      state count: integer
      protocol do
        accepts {:bad}
        emits {:result, value: term}
      end
      on {:bad} do
        x = map_get(count, :key, 0)
        emit {:result, value: x}
      end
    end
    """
    assert {:error, %{type: :type_error}} = Vor.Compiler.compile_string(source)
  end

  test "error: list_head on map state field" do
    source = """
    agent TypeErr3 do
      state store: map
      protocol do
        accepts {:bad}
        emits {:result, value: term}
      end
      on {:bad} do
        x = list_head(store)
        emit {:result, value: x}
      end
    end
    """
    assert {:error, %{type: :type_error}} = Vor.Compiler.compile_string(source)
  end

  test "error: map_sum on list state field" do
    source = """
    agent TypeErr4 do
      state items: list
      protocol do
        accepts {:bad}
        emits {:result, value: integer}
      end
      on {:bad} do
        x = map_sum(items)
        emit {:result, value: x}
      end
    end
    """
    assert {:error, %{type: :type_error}} = Vor.Compiler.compile_string(source)
  end

  # --- No error on term ---

  test "no error on term operations" do
    source = """
    agent TermSafe do
      protocol do
        accepts {:process, value: term}
        emits {:result, value: term}
      end
      on {:process, value: V} do
        x = V + 1
        emit {:result, value: x}
      end
    end
    """
    {:ok, _} = Vor.Compiler.compile_string(source)
  end

  test "no error on extern term result" do
    source = """
    agent ExternTermSafe do
      extern do
        Vor.TestHelpers.Echo.reflect(value: term) :: term
      end
      state count: integer
      protocol do
        accepts {:process}
        emits {:result, value: integer}
      end
      on {:process} do
        x = Vor.TestHelpers.Echo.reflect(value: count)
        y = x + 1
        emit {:result, value: y}
      end
    end
    """
    {:ok, _} = Vor.Compiler.compile_string(source)
  end

  # --- Type propagation ---

  test "map_put result is map, map_size accepts map" do
    source = """
    agent TypeChain do
      state store: map
      protocol do
        accepts {:process}
        emits {:result, value: integer}
      end
      on {:process} do
        updated = map_put(store, :key, 1)
        size = map_size(updated)
        emit {:result, value: size}
      end
    end
    """
    {:ok, _} = Vor.Compiler.compile_string(source)
  end

  test "arithmetic result propagates as integer" do
    source = """
    agent ArithProp do
      state count: integer
      protocol do
        accepts {:process}
        emits {:result, value: integer}
      end
      on {:process} do
        doubled = count + count
        quadrupled = doubled + doubled
        emit {:result, value: quadrupled}
      end
    end
    """
    {:ok, _} = Vor.Compiler.compile_string(source)
  end

  # --- All existing examples compile ---

  test "all examples still compile" do
    for file <- Path.wildcard("examples/*.vor") do
      source = File.read!(file)
      # Single agent files
      if String.contains?(source, "system ") do
        assert {:ok, _} = Vor.Compiler.compile_system(source), "Failed: #{file}"
      else
        assert {:ok, _} = Vor.Compiler.compile_string(source), "Failed: #{file}"
      end
    end
  end
end
