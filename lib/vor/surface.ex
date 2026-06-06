defmodule Vor.Surface do
  @moduledoc """
  Read-only extraction of a `.vor` file's declared specification surface —
  agents, states, protocols, invariants, backpressure, externs, and systems —
  into a structured, JSON-serializable map.

  This is purely a reader: it parses with `Vor.Parser` and walks the AST. It
  runs no verification and never mutates the parser or AST. The output is
  consumed by `mix vor.surface` (JSON or text) and by external tooling that
  wants a machine-readable inventory of what a project declares.
  """

  alias Vor.AST

  @doc """
  Extract the surface of a single source string. Returns `{:ok, file_map}` or
  `{:error, reason}` if the source can't be tokenized/parsed.
  """
  def extract_source(source, file) do
    with {:ok, tokens} <- Vor.Lexer.tokenize(source),
         {:ok, parsed} <- Vor.Parser.parse_multi(tokens) do
      {:ok, extract(parsed, file)}
    end
  end

  @doc """
  Build the per-file map from an already-parsed program
  (`%{agents: [...], system: system | nil}`).
  """
  def extract(%{agents: agents, system: system}, file) do
    %{
      file: file,
      agents: Enum.map(agents || [], &agent_to_map/1),
      systems: system_list(system)
    }
  end

  defp system_list(nil), do: []
  defp system_list(%AST.System{} = system), do: [system_to_map(system)]

  # ---------------------------------------------------------------------------
  # Agents
  # ---------------------------------------------------------------------------

  defp agent_to_map(%AST.Agent{name: name, params: params, body: body, max_queue: struct_mq}) do
    protocol = Enum.find(body, &match?(%AST.Protocol{}, &1))
    # Agent-level `max_queue N` lands in the body as a `{:max_queue, n}` tuple at
    # parse time (it is lifted onto the struct later, during lowering).
    mq = struct_mq || agent_max_queue(body)

    %{
      name: to_string(name),
      type: to_string(agent_behaviour(body)),
      params: Enum.map(params || [], fn {n, t} -> "#{n}: #{t}" end),
      states: for(%AST.StateDecl{} = s <- body, do: state_to_map(s)),
      protocol: protocol_to_map(protocol),
      invariants: for(node <- body, inv = invariant_to_map(node), do: inv),
      backpressure: if(mq, do: %{max_queue: mq}, else: nil),
      externs: for(%AST.ExternBlock{declarations: decls} <- body, d <- decls, do: extern_to_map(d))
    }
  end

  defp agent_max_queue(body) do
    Enum.find_value(body, fn
      {:max_queue, n} -> n
      _ -> nil
    end)
  end

  # Mirrors Vor.Lowering: an agent is a gen_statem iff it declares an enum
  # (atom-union) state field; otherwise it is a gen_server.
  defp agent_behaviour(body) do
    has_enum =
      Enum.any?(body, fn
        %AST.StateDecl{type_union: types} -> enum_type?(types)
        _ -> false
      end)

    if has_enum, do: :gen_statem, else: :gen_server
  end

  defp enum_type?(types) do
    length(types) > 1 and Enum.all?(types, &(not match?({:type, _}, &1)))
  end

  defp state_to_map(%AST.StateDecl{field: field, type_union: types, sensitive: sensitive}) do
    base =
      if enum_type?(types) do
        %{name: to_string(field), type: "enum", values: Enum.map(types, &to_string/1)}
      else
        %{name: to_string(field), type: scalar_type_name(types)}
      end

    if sensitive, do: Map.put(base, :sensitive, true), else: base
  end

  defp scalar_type_name([{:type, t}]), do: to_string(t)
  defp scalar_type_name([single]), do: to_string(single)
  defp scalar_type_name(types), do: Enum.map_join(types, " | ", &to_string/1)

  # ---------------------------------------------------------------------------
  # Protocol
  # ---------------------------------------------------------------------------

  defp protocol_to_map(nil), do: %{accepts: [], emits: []}

  defp protocol_to_map(%AST.Protocol{accepts: accepts, emits: emits}) do
    %{
      accepts: Enum.map(accepts || [], &accepts_to_map/1),
      emits: Enum.map(emits || [], &emits_to_map/1)
    }
  end

  defp accepts_to_map(%AST.MessageSpec{} = m) do
    %{
      tag: to_string(m.tag),
      fields: fields_map(m.fields),
      where: render_constraint(m.constraint),
      max_queue: m.max_queue,
      priority: m.priority == true,
      defaults: defaults_map(m.defaults)
    }
  end

  defp emits_to_map(%AST.MessageSpec{} = m) do
    %{tag: to_string(m.tag), fields: fields_map(m.fields)}
  end

  defp fields_map(fields) do
    Map.new(fields || [], fn {name, type} -> {to_string(name), to_string(type)} end)
  end

  defp defaults_map(defaults) do
    Map.new(defaults || %{}, fn {k, v} -> {to_string(k), v} end)
  end

  # ---------------------------------------------------------------------------
  # Invariants (agent-level safety/liveness)
  # ---------------------------------------------------------------------------

  defp invariant_to_map(%AST.Safety{name: name, tier: tier, body: body, meta: meta}) do
    %{
      kind: "safety",
      name: name,
      tier: tier_str(tier),
      body: render_tokens(body),
      line: line_of(meta)
    }
  end

  defp invariant_to_map(%AST.Liveness{name: name, tier: tier, timeout_expr: te, body: body, meta: meta}) do
    base = %{
      kind: "liveness",
      name: name,
      tier: tier_str(tier),
      body: render_tokens(body),
      line: line_of(meta)
    }

    if te, do: Map.put(base, :within, render_timeout(te)), else: base
  end

  defp invariant_to_map(_), do: nil

  defp render_timeout({:integer, n}), do: n
  defp render_timeout({_kind, v}), do: to_string(v)
  defp render_timeout(other), do: inspect(other)

  # ---------------------------------------------------------------------------
  # Externs
  # ---------------------------------------------------------------------------

  defp extern_to_map(%AST.ExternDecl{module: mod, function: func, args: args, return_type: ret}) do
    %{
      module: render_extern_module(mod),
      function: to_string(func),
      args: fields_map(args),
      return_type: render_type(ret),
      kind: extern_kind(mod)
    }
  end

  defp render_extern_module({:gleam_mod, m}), do: to_string(m)
  defp render_extern_module({:erlang_mod, m}), do: to_string(m)
  defp render_extern_module(m) when is_atom(m), do: to_string(m)
  defp render_extern_module(m), do: inspect(m)

  defp extern_kind({:gleam_mod, _}), do: "gleam"
  defp extern_kind({:erlang_mod, _}), do: "erlang"
  defp extern_kind(_), do: "elixir"

  defp render_type(t) when is_atom(t), do: to_string(t)
  defp render_type(t), do: inspect(t)

  # ---------------------------------------------------------------------------
  # Systems
  # ---------------------------------------------------------------------------

  defp system_to_map(%AST.System{} = s) do
    %{
      name: to_string(s.name),
      agents: Enum.map(s.agents || [], &instance_to_map/1),
      connections:
        Enum.map(s.connections || [], fn %AST.Connect{from: f, to: t} ->
          [to_string(f), to_string(t)]
        end),
      invariants: Enum.map(s.invariants || [], &system_invariant_to_map/1),
      requires: Enum.map(s.requires || [], &requires_to_map/1),
      chaos: chaos_to_map(s.chaos)
    }
  end

  defp instance_to_map(%AST.AgentInstance{name: name, type: type, params: params}) do
    %{
      instance: to_string(name),
      type: to_string(type),
      params: Map.new(params || [], fn {k, v} -> {to_string(k), jsonable(v)} end)
    }
  end

  defp system_invariant_to_map(%AST.SystemSafety{name: n, tier: tier, body: {:liveness_body, tokens}, meta: meta}) do
    %{kind: "liveness", name: n, tier: tier_str(tier), body: render_tokens(tokens), line: line_of(meta)}
  end

  defp system_invariant_to_map(%AST.SystemSafety{name: n, tier: tier, body: body, meta: meta}) do
    %{kind: "safety", name: n, tier: tier_str(tier), body: render_system_body(body), line: line_of(meta)}
  end

  defp requires_to_map(%AST.Requires{target: target, type: type}) do
    %{target: to_string(target), type: to_string(type)}
  end

  defp chaos_to_map(nil), do: nil

  defp chaos_to_map(%AST.ChaosConfig{} = c) do
    c
    |> Map.from_struct()
    |> Map.delete(:meta)
    |> Map.new(fn {k, v} -> {k, jsonable(v)} end)
  end

  # ---------------------------------------------------------------------------
  # Renderers
  # ---------------------------------------------------------------------------

  # Reconstruct a readable expression string from a raw token list (used for
  # invariant bodies, which the parser keeps verbatim as tokens).
  defp render_tokens(tokens) when is_list(tokens) do
    tokens
    |> Enum.map(&token_text/1)
    |> join_tokens()
  end

  defp render_tokens(other), do: inspect(other)

  defp token_text({:keyword, _, a}), do: to_string(a)
  defp token_text({:identifier, _, a}), do: to_string(a)
  defp token_text({:atom, _, s}), do: ":" <> to_string(s)
  defp token_text({:integer, _, n}), do: to_string(n)
  defp token_text({:string, _, s}), do: inspect(s)
  defp token_text({:operator, _, op}), do: operator_text(op)
  defp token_text({:delimiter, _, d}), do: delimiter_text(d)
  defp token_text(other), do: inspect(other)

  defp operator_text(:double_colon), do: "::"
  defp operator_text(:arrow), do: "->"
  defp operator_text(:range), do: ".."
  defp operator_text(:equals), do: "="
  defp operator_text(:star), do: "*"
  defp operator_text(:plus), do: "+"
  defp operator_text(:minus), do: "-"
  defp operator_text(:slash), do: "/"
  defp operator_text(:dot), do: "."
  defp operator_text(op), do: to_string(op)

  defp delimiter_text(:open_brace), do: "{"
  defp delimiter_text(:close_brace), do: "}"
  defp delimiter_text(:open_paren), do: "("
  defp delimiter_text(:close_paren), do: ")"
  defp delimiter_text(:open_bracket), do: "["
  defp delimiter_text(:close_bracket), do: "]"
  defp delimiter_text(:comma), do: ","
  defp delimiter_text(:colon), do: ":"
  defp delimiter_text(:pipe), do: "|"
  defp delimiter_text(d), do: to_string(d)

  @attach_left [")", "}", "]", ",", "(", "{", "[", "."]
  @attach_right ["(", "{", "[", "."]

  defp join_tokens([]), do: ""

  defp join_tokens([first | rest]) do
    {result, _prev} =
      Enum.reduce(rest, {first, first}, fn piece, {acc, prev} ->
        sep = if piece in @attach_left or prev in @attach_right, do: "", else: " "
        {acc <> sep <> piece, piece}
      end)

    result
  end

  # where-clause constraint AST → string
  defp render_constraint(nil), do: nil
  defp render_constraint({:and, l, r}), do: "#{render_constraint(l)} and #{render_constraint(r)}"
  defp render_constraint({:or, l, r}), do: "#{render_constraint(l)} or #{render_constraint(r)}"

  defp render_constraint({op, left, right}) when op in [:>, :<, :>=, :<=, :==, :!=] do
    "#{render_operand(left)} #{op} #{render_operand(right)}"
  end

  defp render_constraint(other), do: inspect(other)

  defp render_operand({:field, f}), do: to_string(f)
  defp render_operand({:literal, v}) when is_integer(v), do: to_string(v)
  defp render_operand({:literal, v}) when is_binary(v), do: ":" <> v
  defp render_operand({:literal, v}) when is_atom(v), do: ":" <> to_string(v)
  defp render_operand(other), do: inspect(other)

  # System safety bodies are kept as structured tuples by the parser; there is
  # no verbatim source to reconstruct, so render a readable inspection.
  defp render_system_body(body), do: inspect(body)

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp tier_str(nil), do: nil
  defp tier_str(tier), do: to_string(tier)

  defp line_of({line, _col}), do: line
  defp line_of(_), do: nil

  # Recursively coerce a value into a JSON-encodable shape (tuples → lists).
  defp jsonable(v) when is_tuple(v), do: v |> Tuple.to_list() |> Enum.map(&jsonable/1)
  defp jsonable(v) when is_list(v), do: Enum.map(v, &jsonable/1)
  defp jsonable(%_{} = struct), do: struct |> Map.from_struct() |> jsonable()
  defp jsonable(v) when is_map(v), do: Map.new(v, fn {k, val} -> {jsonable_key(k), jsonable(val)} end)
  defp jsonable(v), do: v

  defp jsonable_key(k) when is_atom(k), do: k
  defp jsonable_key(k), do: to_string(k)
end
