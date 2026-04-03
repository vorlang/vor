defmodule Vor.Examples.LockHelpers do
  @moduledoc "Queue operations for the distributed lock example"

  def queue_push(queue, item) when is_list(queue), do: queue ++ [item]
  def queue_push(_, item), do: [item]

  def queue_head([head | _]), do: head
  def queue_head(_), do: :none

  def queue_tail([_ | tail]), do: tail
  def queue_tail(_), do: []

  def queue_empty([]), do: :true
  def queue_empty(list) when is_list(list), do: :false
  def queue_empty(_), do: :true

  def queue_length(queue) when is_list(queue), do: length(queue)
  def queue_length(_), do: 0
end
