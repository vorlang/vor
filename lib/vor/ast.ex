defmodule Vor.AST do
  @moduledoc """
  AST node definitions for the Vor language.
  """

  defmodule Agent do
    defstruct [:name, :params, :body, :meta]
  end

  defmodule Protocol do
    defstruct [:accepts, :emits, :sends, :meta]
  end

  defmodule MessageSpec do
    defstruct [:tag, :fields, :meta]
  end

  defmodule Handler do
    defstruct [:pattern, :guard, :body, :meta]
  end

  defmodule Pattern do
    defstruct [:tag, :bindings, :meta]
  end

  defmodule Emit do
    defstruct [:tag, :fields, :meta]
  end

  defmodule StateDecl do
    defstruct [:field, :type_union, :meta]
  end

  defmodule Transition do
    defstruct [:field, :value, :meta]
  end

  defmodule Relation do
    defstruct [:name, :params, :facts, :equation, :meta]
  end

  defmodule Fact do
    defstruct [:fields, :meta]
  end

  defmodule Safety do
    defstruct [:name, :tier, :body, :meta]
  end

  defmodule Liveness do
    defstruct [:name, :tier, :timeout_expr, :body, :meta]
  end

  defmodule Resilience do
    defstruct [:handlers, :meta]
  end

  defmodule ResilienceHandler do
    defstruct [:invariant_name, :actions, :meta]
  end

  defmodule Guard do
    defstruct [:field, :op, :value, :meta]
  end

  defmodule CompoundGuard do
    defstruct [:op, :left, :right, :meta]
  end

  defmodule StartTimer do
    defstruct [:name, :meta]
  end

  defmodule CancelTimer do
    defstruct [:name, :meta]
  end

  defmodule RestartTimer do
    defstruct [:name, :args, :meta]
  end

  defmodule FunctionCall do
    defstruct [:name, :args, :meta]
  end

  defmodule ExternBlock do
    defstruct [:declarations, :meta]
  end

  defmodule ExternDecl do
    defstruct [:module, :function, :args, :return_type, :meta]
  end

  defmodule ExternCall do
    defstruct [:module, :function, :args, :bind, :meta]
  end

  defmodule IfElse do
    defstruct [:condition, :then_body, :else_body, :meta]
  end

  defmodule Comparison do
    defstruct [:left, :op, :right, :meta]
  end

  defmodule ArithExpr do
    defstruct [:op, :left, :right, :meta]
  end

  defmodule VarRef do
    defstruct [:name, :meta]
  end

  defmodule VarBinding do
    defstruct [:name, :expr, :meta]
  end

  defmodule CompoundComparison do
    defstruct [:op, :left, :right, :meta]
  end

  defmodule Send do
    defstruct [:target, :tag, :fields, :meta]
  end

  defmodule Broadcast do
    defstruct [:tag, :fields, :meta]
  end

  defmodule Noop do
    defstruct [:meta]
  end

  defmodule MapOp do
    defstruct [:op, :args, :meta]
  end

  defmodule MinMax do
    defstruct [:op, :left, :right, :meta]
  end

  defmodule System do
    defstruct [:name, :agents, :connections, :meta]
  end

  defmodule AgentInstance do
    defstruct [:name, :type, :params, :meta]
  end

  defmodule Connect do
    defstruct [:from, :to, :meta]
  end

  defmodule Solve do
    defstruct [:relation, :bindings, :body, :meta]
  end

  defmodule RelationEquation do
    defstruct [:lhs, :rhs, :meta]
  end
end
