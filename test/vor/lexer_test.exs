defmodule Vor.LexerTest do
  use ExUnit.Case, async: true

  test "tokenizes minimal agent skeleton" do
    {:ok, tokens} = Vor.Lexer.tokenize("agent Echo do end")
    types = Enum.map(tokens, fn {type, _, _} -> type end)
    values = Enum.map(tokens, fn {_, _, v} -> v end)
    assert types == [:keyword, :identifier, :keyword, :keyword]
    assert values == [:agent, :Echo, :do, :end]
  end

  test "tokenizes atom literal" do
    {:ok, [{:atom, _, "ping"}]} = Vor.Lexer.tokenize(":ping")
  end

  test "tokenizes message pattern" do
    {:ok, tokens} = Vor.Lexer.tokenize("{:ping, payload: P}")
    types = Enum.map(tokens, fn {type, _, _} -> type end)
    assert :delimiter in types
    assert :atom in types
    assert :identifier in types
  end

  test "tokenizes integer" do
    {:ok, [{:integer, _, 42}]} = Vor.Lexer.tokenize("42")
  end

  test "tokenizes string" do
    {:ok, [{:string, _, "hello world"}]} = Vor.Lexer.tokenize(~s("hello world"))
  end

  test "skips comments" do
    {:ok, tokens} = Vor.Lexer.tokenize("%% this is a comment\nagent")
    assert [{:keyword, _, :agent}] = tokens
  end

  test "tokenizes operators" do
    {:ok, tokens} = Vor.Lexer.tokenize("-> == ..")
    values = Enum.map(tokens, fn {_, _, v} -> v end)
    assert values == [:arrow, :==, :range]
  end

  test "tokenizes the echo agent" do
    source = File.read!("test/fixtures/echo.vor")
    {:ok, tokens} = Vor.Lexer.tokenize(source)
    assert length(tokens) > 0
    # Verify key tokens are present
    values = Enum.map(tokens, fn {_, _, v} -> v end)
    assert :agent in values
    assert :protocol in values
    assert :accepts in values
    assert :emits in values
    assert :on in values
    assert :emit in values
  end
end
