defmodule Vor.Examples.RaftHelpers do
  @moduledoc """
  Pure data helpers for the Raft example.
  Only list operations and arithmetic — no communication.
  """

  def log_append(log, term, command) when is_list(log) do
    log ++ [{term, command}]
  end
  def log_append(_, term, command), do: [{term, command}]

  def log_last_index(log) when is_list(log), do: length(log)
  def log_last_index(_), do: 0

  def log_last_term(log) when is_list(log) do
    case List.last(log) do
      {term, _} -> term
      nil -> 0
    end
  end
  def log_last_term(_), do: 0

  def log_up_to_date(candidate_last_index, candidate_last_term, my_log) when is_list(my_log) do
    my_last_term = log_last_term(my_log)
    my_last_index = log_last_index(my_log)
    cond do
      candidate_last_term > my_last_term -> :true
      candidate_last_term < my_last_term -> :false
      candidate_last_index >= my_last_index -> :true
      true -> :false
    end
  end
  def log_up_to_date(_, _, _), do: :true

  def majority(cluster_size) when is_integer(cluster_size) do
    div(cluster_size, 2) + 1
  end
end
