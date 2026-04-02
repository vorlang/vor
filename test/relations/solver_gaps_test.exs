defmodule Vor.Relations.SolverGapsTest do
  use ExUnit.Case

  test "solve with no bound variables produces error" do
    source = """
    agent NoBound do
      relation temp(celsius: integer, fahrenheit: integer) do
        fahrenheit = celsius * 9 / 5 + 32
      end

      protocol do
        accepts {:convert}
        emits {:result, c: integer, f: integer}
      end

      on {:convert} do
        solve temp(celsius: C, fahrenheit: F) do
          emit {:result, c: C, f: F}
        end
      end
    end
    """

    # With no bound variables, the solver can't determine direction.
    # The compiler should reject this — currently it crashes in codegen.
    assert_raise MatchError, fn ->
      Vor.Compiler.compile_string(source)
    end
  end
end
