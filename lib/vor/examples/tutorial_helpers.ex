defmodule Vor.Examples.TutorialHelpers do
  @table :tutorial_rate_counts

  def start do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end
    :ok
  end

  def increment(client, window_ms) do
    start()
    now = System.monotonic_time(:millisecond)
    key = {client, div(now, window_ms)}
    :ets.update_counter(@table, key, {2, 1}, {key, 0})
  end

  def reset do
    if :ets.whereis(@table) != :undefined do
      :ets.delete_all_objects(@table)
    end
    :ok
  end
end
