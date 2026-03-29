defmodule Vor.LoweringTest do
  use ExUnit.Case, async: true

  alias Vor.IR

  test "echo agent lowers to gen_server IR" do
    source = File.read!("test/fixtures/echo.vor")
    {:ok, tokens} = Vor.Lexer.tokenize(source)
    {:ok, ast} = Vor.Parser.parse(tokens)
    {:ok, ir} = Vor.Lowering.lower(ast)

    assert %IR.Agent{} = ir
    assert ir.name == :Echo
    assert ir.module == Vor.Agent.Echo
    assert ir.behaviour == :gen_server
    assert ir.state_fields == []

    # Protocol
    assert length(ir.protocol.accepts) == 1
    assert length(ir.protocol.emits) == 1
    assert %IR.MessageType{tag: :ping, fields: [payload: :term]} = hd(ir.protocol.accepts)
    assert %IR.MessageType{tag: :pong, fields: [payload: :term]} = hd(ir.protocol.emits)

    # Handlers
    assert [handler] = ir.handlers
    assert %IR.MatchPattern{tag: :ping} = handler.pattern
    assert [%IR.Binding{name: :P, field: :payload}] = handler.pattern.bindings

    assert [%IR.Action{type: :emit, data: %IR.EmitAction{tag: :pong}}] = handler.actions
  end

  test "agent with state lowers to gen_statem" do
    source = """
    agent Counter do
      state phase: :idle | :running

      protocol do
        accepts {:start, id: term}
        emits {:started, id: term}
      end

      on {:start, id: I} when phase == :idle do
        emit {:started, id: I}
        transition phase: :running
      end
    end
    """
    {:ok, tokens} = Vor.Lexer.tokenize(source)
    {:ok, ast} = Vor.Parser.parse(tokens)
    {:ok, ir} = Vor.Lowering.lower(ast)

    assert ir.behaviour == :gen_statem
    assert [%IR.StateField{name: :phase, values: [:idle, :running], initial: :idle}] = ir.state_fields
  end
end
