defmodule TravelingPoet.Messaging.Dedupe do
  @moduledoc """
  Remembers message ids we've already handled, so provider retries don't make
  the poet answer twice. The Telegram poller gets this for free from its
  update offset; WhatsApp webhooks are at-least-once and will redeliver until
  we 200, so anything webhook-fed has to check in here first.

  In-memory and single-node on purpose: retries arrive within minutes, and a
  restart losing the set is at worst one duplicate reply.
  """

  use GenServer

  @table :messaging_dedupe
  # Meta retries for a while; an hour of memory covers it comfortably.
  @ttl_seconds 3600
  @prune_interval_ms 10 * 60 * 1000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  True the first time an id is seen, false afterwards. Unknown/blank ids are
  always treated as fresh — better a duplicate than a dropped message.
  """
  def fresh?(id) when is_binary(id) and id != "" do
    ensure_table()
    :ets.insert_new(@table, {id, System.system_time(:second)})
  end

  def fresh?(_), do: true

  @impl true
  def init(_opts) do
    ensure_table()
    schedule_prune()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:prune, state) do
    cutoff = System.system_time(:second) - @ttl_seconds
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    schedule_prune()
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])

      _ ->
        @table
    end
  rescue
    # Two processes racing to create the table: the loser is fine either way.
    ArgumentError -> @table
  end

  defp schedule_prune, do: Process.send_after(self(), :prune, @prune_interval_ms)
end
