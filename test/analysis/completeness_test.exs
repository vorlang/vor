defmodule Vor.Analysis.CompletenessTest do
  use ExUnit.Case

  test "handler with if/emit and no else produces compile error" do
    source = """
    agent MissingElse do
      protocol do
        accepts {:check, value: integer}
        emits {:ok, result: integer}
      end

      on {:check, value: V} do
        if V > 0 do
          emit {:ok, result: V}
        end
      end
    end
    """

    assert {:error, %{type: :incomplete_handler}} = Vor.Compiler.compile_string(source)
  end

  test "handler with if/emit and else/emit compiles" do
    source = """
    agent CompleteHandler do
      protocol do
        accepts {:check, value: integer}
        emits {:ok, result: integer}
        emits {:rejected, reason: atom}
      end

      on {:check, value: V} do
        if V > 0 do
          emit {:ok, result: V}
        else
          emit {:rejected, reason: :non_positive}
        end
      end
    end
    """

    {:ok, _mod} = Vor.Compiler.compile_string(source)
  end

  test "handler with default emit after if compiles" do
    source = """
    agent DefaultEmit do
      state count: integer

      protocol do
        accepts {:process, value: integer}
        emits {:done, count: integer}
      end

      on {:process, value: V} do
        if V > 0 do
          transition count: count + V
        end
        emit {:done, count: count}
      end
    end
    """

    {:ok, _mod} = Vor.Compiler.compile_string(source)
  end

  test "cast handler without else is ok" do
    source = """
    agent CastOk do
      state count: integer

      protocol do
        accepts {:maybe_increment, value: integer}
      end

      on {:maybe_increment, value: V} do
        if V > 0 do
          transition count: count + V
        end
      end
    end
    """

    {:ok, _mod} = Vor.Compiler.compile_string(source)
  end

  test "nested if with incomplete emit coverage produces error" do
    source = """
    agent NestedIncomplete do
      protocol do
        accepts {:check, a: integer, b: integer}
        emits {:big}
        emits {:small}
        emits {:negative}
      end

      on {:check, a: A, b: B} do
        if A > 0 do
          if A > 100 do
            emit {:big}
          end
        else
          emit {:negative}
        end
      end
    end
    """

    assert {:error, %{type: :incomplete_handler}} = Vor.Compiler.compile_string(source)
  end

  test "nested if with complete emit coverage compiles" do
    source = """
    agent NestedComplete do
      protocol do
        accepts {:check, a: integer, b: integer}
        emits {:big}
        emits {:small}
        emits {:negative}
      end

      on {:check, a: A, b: B} do
        if A > 0 do
          if A > 100 do
            emit {:big}
          else
            emit {:small}
          end
        else
          emit {:negative}
        end
      end
    end
    """

    {:ok, _mod} = Vor.Compiler.compile_string(source)
  end
end
