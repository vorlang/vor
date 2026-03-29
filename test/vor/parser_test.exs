defmodule Vor.ParserTest do
  use ExUnit.Case, async: true

  alias Vor.AST

  test "parses echo agent" do
    source = File.read!("test/fixtures/echo.vor")
    {:ok, tokens} = Vor.Lexer.tokenize(source)
    {:ok, ast} = Vor.Parser.parse(tokens)

    assert %AST.Agent{name: :Echo} = ast
    assert length(ast.body) == 2

    [proto, handler] = ast.body
    assert %AST.Protocol{} = proto
    assert length(proto.accepts) == 1
    assert length(proto.emits) == 1

    assert %AST.Handler{} = handler
    assert %AST.Pattern{tag: "ping"} = handler.pattern
    assert [%AST.Emit{tag: "pong"}] = handler.body
  end

  test "parses protocol accepts and emits" do
    source = """
    agent Test do
      protocol do
        accepts {:request, id: integer}
        emits {:response, id: integer}
      end
    end
    """
    {:ok, tokens} = Vor.Lexer.tokenize(source)
    {:ok, ast} = Vor.Parser.parse(tokens)

    [proto] = ast.body
    assert [%AST.MessageSpec{tag: "request", fields: [id: :integer]}] = proto.accepts
    assert [%AST.MessageSpec{tag: "response", fields: [id: :integer]}] = proto.emits
  end

  test "parses handler with emit" do
    source = """
    agent Test do
      protocol do
        accepts {:ping, payload: term}
        emits {:pong, payload: term}
      end
      on {:ping, payload: P} do
        emit {:pong, payload: P}
      end
    end
    """
    {:ok, tokens} = Vor.Lexer.tokenize(source)
    {:ok, ast} = Vor.Parser.parse(tokens)

    [_proto, handler] = ast.body
    assert %AST.Handler{} = handler
    assert handler.pattern.tag == "ping"
    assert [payload: {:var, :P}] = handler.pattern.bindings
    assert [%AST.Emit{tag: "pong", fields: [payload: {:var, :P}]}] = handler.body
  end
end
