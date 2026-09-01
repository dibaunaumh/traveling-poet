defmodule TravelingPoet.FirstEntry.Watchdog do
  @moduledoc """
  Retries first-entry kickoffs for poets that are still waiting.

  The LiveView fast path only helps someone sitting on the setting-up screen.
  This is what covers everyone else: the person who closed the tab because the
  screen told them they could, and the poet whose first `/onboard` landed
  during an outage.

  Ticks every `:first_entry_check_interval_minutes` (env
  FIRST_ENTRY_CHECK_INTERVAL_MINUTES, default 5; 0 disables, and test sets 0).
  `TravelingPoet.FirstEntry` owns the attempt cap and spacing, so a tick this
  frequent is cheap — almost every one finds nothing to do.
  """

  use GenServer
  require Logger

  alias TravelingPoet.FirstEntry

  # Someone waiting on their first entry shouldn't have a deploy add another
  # interval to the wait.
  @startup_delay_ms 30_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    case interval_ms() do
      0 ->
        Logger.info("FirstEntry.Watchdog: disabled")

      interval ->
        Logger.info("FirstEntry.Watchdog: checking every #{div(interval, 60_000)}m")
        Process.send_after(self(), :check, min(@startup_delay_ms, interval))
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info(:check, state) do
    case FirstEntry.sweep() do
      [] -> :ok
      started -> Logger.info("FirstEntry.Watchdog: kicked off #{inspect(started)}")
    end

    Process.send_after(self(), :check, interval_ms())
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp interval_ms do
    Application.get_env(:traveling_poet, :first_entry_check_interval_minutes, 0) * 60_000
  end
end
