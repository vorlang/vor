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
      :params,
      :state_fields,
      :data_fields,
      :protocol,
      :handlers,
      :relations,
      :invariants,
      :resilience,
      :externs,
      :monitors,
      :periodic_timers,
      :init_handler
    ]
  end

  defmodule Protocol do
    defstruct [:accepts, :emits, :sends]
  end

  defmodule MessageType do
    defstruct [:tag, :fields, constraint: nil]
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
    defstruct [:name, :params, :facts, :equation]
  end

  defmodule ExternDecl do
    defstruct [:module, :function, :args, :return_type, :trusted]
  end

  defmodule ExternCallAction do
    defstruct [:module, :function, :args, :bind, :trusted]
  end

  defmodule ConditionalAction do
    defstruct [:condition, :then_actions, :else_actions]
  end

  defmodule Condition do
    defstruct [:left, :op, :right]
  end

  defmodule DataField do
    defstruct [:name, :type, :default, sensitive: false]
  end

  defmodule VarBindingAction do
    defstruct [:name, :expr]
  end

  defmodule CompoundCondition do
    defstruct [:op, :left, :right]
  end

  defmodule SolveAction do
    defstruct [:relation_name, :bindings, :bound_fields, :unbound_fields, :body_actions, :equation, :facts]
  end

  defmodule SendAction do
    defstruct [:target, :tag, :fields]
  end

  defmodule BroadcastAction do
    defstruct [:tag, :fields]
  end

  defmodule SystemIR do
    defstruct [:name, :registry, :agents, :connections, invariants: [], chaos: nil, requires: []]
  end

  defmodule ChaosConfig do
    defstruct duration_ms: 30_000,
              seed: nil,
              kill: nil,
              partition: nil,
              delay: nil,
              drop: nil,
              workload: nil,
              check: nil
  end

  # System-level invariant. body is a structured tuple for safety, or
  # {:liveness_body, tokens} for liveness (parsed later by LivenessChecker).
  defmodule SystemInvariant do
    defstruct [:name, :tier, :body, kind: :safety]
  end

  defmodule AgentInstanceIR do
    defstruct [:name, :module, :type_name, :params, :behaviour]
  end

  defmodule PeriodicTimer do
    defstruct [:tag, :interval, :actions]
  end

  defmodule LivenessMonitor do
    defstruct [:name, :timeout_expr, :excluded_states, :target_state, :monitored_states, :resilience_actions, :event_tag]
  end
end
