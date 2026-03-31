defmodule Vor.IR do
  @moduledoc """
  Core intermediate representation for the Vor compiler.
  Semantic model closer to the OTP target than the AST.
  """

  defmodule Agent do
    defstruct [
      :name,
      :module,
      :behaviour,
      :state_fields,
      :protocol,
      :handlers,
      :relations,
      :invariants,
      :resilience,
      :externs
    ]
  end

  defmodule Protocol do
    defstruct [:accepts, :emits]
  end

  defmodule MessageType do
    defstruct [:tag, :fields]
  end

  defmodule Handler do
    defstruct [:pattern, :guard, :actions]
  end

  defmodule MatchPattern do
    defstruct [:tag, :bindings]
  end

  defmodule Binding do
    defstruct [:name, :field]
  end

  defmodule Action do
    defstruct [:type, :data]
  end

  defmodule EmitAction do
    defstruct [:tag, :fields]
  end

  defmodule TransitionAction do
    defstruct [:field, :value]
  end

  defmodule TimerAction do
    defstruct [:op, :name, :args]
  end

  defmodule FunctionCallAction do
    defstruct [:name, :args]
  end

  defmodule StateField do
    defstruct [:name, :values, :initial]
  end

  defmodule GuardExpr do
    defstruct [:field, :op, :value]
  end

  defmodule CompoundGuardExpr do
    defstruct [:op, :left, :right]
  end

  defmodule Relation do
    defstruct [:name, :params, :facts]
  end

  defmodule ExternDecl do
    defstruct [:module, :function, :args, :return_type, :trusted]
  end

  defmodule ExternCallAction do
    defstruct [:module, :function, :args, :bind, :trusted]
  end
end
