defmodule TravelingPoet.Analytics.Server do
  @moduledoc """
  Owns the per-visitor rate counter (an ETS table), rebuilds the
  `funnel_days` rollups every 15 minutes (`Analytics.Rollup`), and prunes
  visit events past `Analytics.retention_days/0` once a day. Both database
  jobs are off in test (`:analytics_prune`), where the sandbox owns the Repo.
  """
  use GenServer

  alias TravelingPoet.Analytics

  require Logger

  @day :timer.hours(24)
  @sweep :timer.minutes(5)
  @rollup :timer.minutes(15)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(Analytics.rate_table(), [:named_table, :public, write_concurrency: true])
    Process.send_after(self(), :sweep, @sweep)

    if Application.get_env(:traveling_poet, :analytics_prune, true) do
      Process.send_after(self(), :prune, :timer.hours(1))
      Process.send_after(self(), :rollup, :timer.minutes(1))
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    # Counters are keyed by minute; anything older than this one is spent.
    minute = System.system_time(:second) |> div(60)

    :ets.select_delete(Analytics.rate_table(), [
      {{{:_, :"$1"}, :_}, [{:<, :"$1", minute}], [true]}
    ])

    Process.send_after(self(), :sweep, @sweep)
    {:noreply, state}
  end

  def handle_info(:rollup, state) do
    TravelingPoet.Analytics.Rollup.run()
    Process.send_after(self(), :rollup, @rollup)
    {:noreply, state}
  rescue
    e ->
      Logger.warning("analytics: rollup failed: #{Exception.message(e)}")
      Process.send_after(self(), :rollup, @rollup)
      {:noreply, state}
  end

  def handle_info(:prune, state) do
    n = Analytics.prune()
    if n > 0, do: Logger.info("analytics: pruned #{n} visit events")
    Process.send_after(self(), :prune, @day)
    {:noreply, state}
  rescue
    e ->
      Logger.warning("analytics: prune failed: #{Exception.message(e)}")
      Process.send_after(self(), :prune, @day)
      {:noreply, state}
  end
end
