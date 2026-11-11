defmodule TravelingPoet.AiC.ReadTally do
  @moduledoc """
  Adds up how long an owner spent on each part of their page and reports it
  to Alice-in-Context once a minute, as one `read` event per reader, page and
  part (`TravelingPoet.AiC.part_read/4`).

  The page reports reading every twenty seconds, paragraph by paragraph
  (`TravelingPoet.Reading`); sent on as it arrives that would be an event per
  paragraph per flush. Here it is summed by part (`Journal.PageFacts` ids) and
  sent as seconds. A part opened and left at once still counts, as a read of
  no time: it was seen.

  Only ever fed for an owner with reading signals on. Holds nothing when AiC
  is not configured.
  """

  use GenServer

  alias TravelingPoet.AiC

  @flush_ms 60_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Adds `ms` of reading of `part` of `entry` by `user`. A nil part is dropped."
  def add(_user, _entry, nil, _ms), do: :ok

  def add(user, entry, part, ms) when is_binary(part) and is_integer(ms) and ms >= 0 do
    if AliceInContext.enabled?() do
      GenServer.cast(
        __MODULE__,
        {:add, Map.take(user, [:id, :name]),
         Map.take(entry, [:id, :poet_id, :title, :entry_date]), part, ms}
      )
    end

    :ok
  end

  @doc "Sends what has been tallied so far. For tests and shutdown."
  def flush, do: GenServer.call(__MODULE__, :flush)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:add, user, entry, part, ms}, tally) do
    if tally == %{}, do: Process.send_after(self(), :flush, @flush_ms)

    {:noreply,
     Map.update(tally, {user.id, entry.id, part}, {user, entry, ms}, fn {u, e, total} ->
       {u, e, total + ms}
     end)}
  end

  @impl true
  def handle_call(:flush, _from, tally), do: {:reply, :ok, send_all(tally)}

  @impl true
  def handle_info(:flush, tally), do: {:noreply, send_all(tally)}
  def handle_info(_other, tally), do: {:noreply, tally}

  # A deploy must not lose the last minute of reading.
  @impl true
  def terminate(_reason, tally), do: send_all(tally)

  defp send_all(tally) do
    Enum.each(tally, fn {{_user_id, _entry_id, part}, {user, entry, ms}} ->
      AiC.part_read(user, entry, part, round(ms / 1000))
    end)

    %{}
  end
end
