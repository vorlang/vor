defmodule Vor.Examples.RateStore do
  @moduledoc """
  Simple ETS-based sliding window rate counter.
  Used by the Vor RateLimiter example via extern declarations.
  """

  @table :vor_rate_store

  def start do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end
    :ok
  end

  @doc """
  Increment the counter for a client within a time window.
  Returns the new count. Expired entries are cleaned up automatically.
  """
  def increment(client, window_ms) do
    start()
    now = System.monotonic_time(:millisecond)
    key = {client, window_key(now, window_ms)}

    count = :ets.update_counter(@table, key, {2, 1}, {key, 0})
    cleanup(client, now, window_ms)
    count
  end

  @doc """
  Get the current count for a client within the current window.
  """
  def count(client, window_ms) do
    start()
    now = System.monotonic_time(:millisecond)
    key = {client, window_key(now, window_ms)}

    case :ets.lookup(@table, key) do
      [{_, count}] -> count
      [] -> 0
    end
  end

  defp window_key(now, window_ms) do
    div(now, window_ms)
  end

  defp cleanup(client, now, window_ms) do
    old_key = {client, window_key(now, window_ms) - 1}
    :ets.delete(@table, old_key)
  rescue
    _ -> :ok
  end

  @doc """
  Reset all counters. Useful for testing.
  """
  def reset do
    if :ets.whereis(@table) != :undefined do
      :ets.delete_all_objects(@table)
    end
    :ok
  end
end
