defmodule TravelingPoet.Markers.Watchdog do
  @moduledoc """
  Sends pending feedback markers to the poet once the reader has gone quiet.

  Ticks every `:marker_delivery_interval_minutes` (env
  MARKER_DELIVERY_INTERVAL_MINUTES, default 5; 0 disables, and test sets 0).
  `TravelingPoet.Markers.Delivery` owns the quiet period and the busy guard,
  so a tick this frequent is cheap: almost every one finds nothing to do.
  """

  use GenServer
  require Logger

  alias TravelingPoet.Markers.Delivery

  @startup_delay_ms 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    case interval_ms() do
      0 ->
        Logger.info("Markers.Watchdog: disabled")

      interval ->
        Logger.info("Markers.Watchdog: checking every #{div(interval, 60_000)}m")
        Process.send_after(self(), :check, min(@startup_delay_ms, interval))
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info(:check, state) do
    case Delivery.sweep() do
      [] -> :ok
      started -> Logger.info("Markers.Watchdog: sent digests #{inspect(started)}")
    end

    Process.send_after(self(), :check, interval_ms())
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp interval_ms do
    Application.get_env(:traveling_poet, :marker_delivery_interval_minutes, 0) * 60_000
  end
end
