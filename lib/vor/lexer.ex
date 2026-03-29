defmodule Vor.Lexer do
  @moduledoc """
  NimbleParsec-based tokenizer for the Vor language.

  Produces a flat list of `{type, {line, col}, value}` tokens.
  Keywords produce `{:keyword, {line, col}, atom}` tokens.
  """

  import NimbleParsec

  # --- Whitespace & Comments ---

  whitespace =
    ascii_string([?\s, ?\t, ?\r, ?\n], min: 1)
    |> label("whitespace")

  comment =
    string("%%")
    |> repeat(utf8_char(not: ?\n))
    |> optional(utf8_char([?\n]))
    |> label("comment")

  ignorable =
    choice([whitespace, comment])
    |> times(min: 1)
    |> ignore()

  # --- Helpers ---

  defp to_token(rest, [{value, {line, col}}], context, _position, _byte_offset, type) do
    {rest, [{type, {line, col}, value}], context}
  end

  defp keyword_or_ident(rest, [{name, {line, col}}], context, _position, _byte_offset) do
    keywords = ~w(agent do end protocol accepts emits on emit when state transition
                   safety liveness invariant monitored proven checked resilience
                   relation fact synthesize property never always eventually implies
                   forall where and or not in start_timer cancel_timer restart_timer
                   retransmit_last_response)

    type = if name in keywords, do: :keyword, else: :identifier
    {rest, [{type, {line, col}, String.to_atom(name)}], context}
  end

  # --- Atoms ---
  # :some_name or :some_name123
  atom_name =
    ascii_char([?a..?z, ?_])
    |> repeat(ascii_char([?a..?z, ?A..?Z, ?0..?9, ?_]))
    |> reduce({List, :to_string, []})

  atom_literal =
    ignore(string(":"))
    |> concat(
      atom_name
      |> pre_traverse({:mark_position, []})
      |> post_traverse({:to_token, [:atom]})
    )

  # --- Identifiers & Keywords ---
  # Start with letter or underscore, followed by alphanumeric or underscore
  ident_chars =
    ascii_char([?a..?z, ?A..?Z, ?_])
    |> repeat(ascii_char([?a..?z, ?A..?Z, ?0..?9, ?_]))
    |> reduce({List, :to_string, []})
    |> pre_traverse({:mark_position, []})
    |> post_traverse({:keyword_or_ident, []})

  # --- Integers ---
  integer_literal =
    integer(min: 1)
    |> pre_traverse({:mark_position, []})
    |> post_traverse({:to_token, [:integer]})

  # --- Strings ---
  string_literal =
    ignore(string("\""))
    |> repeat(
      choice([
        string("\\\"") |> replace(?"),
        string("\\n") |> replace(?\n),
        string("\\\\") |> replace(?\\),
        utf8_char(not: ?", not: ?\\)
      ])
    )
    |> ignore(string("\""))
    |> reduce({List, :to_string, []})
    |> pre_traverse({:mark_position, []})
    |> post_traverse({:to_token, [:string]})

  # --- Operators and Delimiters ---
  # Multi-char operators first (longest match)
  operator =
    choice([
      string("->") |> replace(:arrow),
      string("<=") |> replace(:<=),
      string(">=") |> replace(:>=),
      string("==") |> replace(:==),
      string("!=") |> replace(:!=),
      string("..") |> replace(:range),
      string("*") |> replace(:star),
      string("+") |> replace(:plus),
      string("-") |> replace(:minus),
      string("/") |> replace(:slash)
    ])
    |> pre_traverse({:mark_position, []})
    |> post_traverse({:to_token, [:operator]})

  delimiter =
    choice([
      string("{") |> replace(:open_brace),
      string("}") |> replace(:close_brace),
      string("(") |> replace(:open_paren),
      string(")") |> replace(:close_paren),
      string(",") |> replace(:comma),
      string(":") |> replace(:colon),
      string("|") |> replace(:pipe)
    ])
    |> pre_traverse({:mark_position, []})
    |> post_traverse({:to_token, [:delimiter]})

  # --- Token ---
  token =
    choice([
      ignorable,
      string_literal,
      atom_literal,
      operator,
      delimiter,
      integer_literal,
      ident_chars
    ])

  defparsec(:tokenize_raw, repeat(token) |> eos(), inline: true)

  # Position tracking helper
  defp mark_position(rest, args, context, {line, col} = _position, _byte_offset) do
    value = case args do
      [v] -> v
      _ -> args
    end
    {rest, [{value, {line, col}}], context}
  end

  @doc """
  Tokenize a Vor source string.

  Returns `{:ok, tokens}` or `{:error, message, line, col}`.
  """
  def tokenize(source) do
    case tokenize_raw(source) do
      {:ok, tokens, "", _context, _line, _col} ->
        {:ok, tokens}

      {:ok, _tokens, rest, _context, {line, col}, _byte_offset} ->
        {:error, "unexpected character: #{inspect(String.first(rest))}", line, col}

      {:error, message, _rest, _context, {line, col}, _byte_offset} ->
        {:error, message, line, col}
    end
  end
end
