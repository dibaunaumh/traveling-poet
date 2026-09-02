defmodule TravelingPoet.ChangeStream.Worker do
  @moduledoc """
  The timer behind the change stream: every `:change_stream_poll_seconds`
  (env CHANGE_STREAM_POLL_SECONDS; 0/absent disables) it captures, delivers
  and prunes — but only while at least one endpoint is registered, so an app
  with no consumers does no hashing at all.

  Same shape as `FleetHealth.Alerter`: one GenServer, `Process.send_after`,
  a short startup delay so a deploy doesn't defer the first pass by a full
  interval, and `check_now/0` for the console. GenServer serialisation is
  what guarantees two passes never overlap.
  """

  use GenServer
  require Logger

  alias TravelingPoet.ChangeStream

  @startup_delay_ms 15_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    # The enabled flag lives in persistent_term; rebuild it from the DB on boot.
    ChangeStream.refresh_enabled!()

    case interval_ms() do
      0 ->
        Logger.info("ChangeStream.Worker: disabled")

      interval ->
        Logger.info("ChangeStream.Worker: polling every #{div(interval, 1000)}s")
        Process.send_after(self(), :tick, min(@startup_delay_ms, interval))
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    run()
    Process.send_after(self(), :tick, interval_ms())
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @doc "Runs one pass immediately, ignoring the schedule. Handy from a console."
  def check_now, do: GenServer.call(__MODULE__, :check_now, 60_000)

  @impl true
  def handle_call(:check_now, _from, state) do
    {:reply, run(), state}
  end

  defp run do
    if ChangeStream.enabled?() do
      ChangeStream.run_once(DateTime.utc_now())
    else
      :disabled
    end
  end

  defp interval_ms do
    Application.get_env(:traveling_poet, :change_stream_poll_seconds, 0) * 1000
  end
end
