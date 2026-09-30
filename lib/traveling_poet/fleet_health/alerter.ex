defmodule TravelingPoet.FleetHealth.Alerter do
  @moduledoc """
  Watches `TravelingPoet.FleetHealth` and reports missed days over Telegram,
  so a silent fleet doesn't stay silent until someone happens to open the
  landing page.

  Checks hourly (`:fleet_health_check_interval_minutes`, env
  FLEET_HEALTH_CHECK_INTERVAL_MINUTES; 0/absent disables). Each poet is
  reported at most once per UTC day — a fleet-wide outage is one message a
  day, not one an hour. A poet's alert is remembered as a `fleet_alert` usage
  row, so it survives a deploy: kept in the process, four deploys on
  2026-09-30 paged Udi about Samuel's poet four times. The budget warning is
  still remembered in the process only.

  Recipients: see `TravelingPoet.Alerts`.
  """

  use GenServer
  require Logger

  import Ecto.Query

  alias TravelingPoet.{Alerts, FleetHealth, OpenRouter, Repo, Usage}
  alias TravelingPoet.Usage.UsageEvent

  # First check soon after boot: an interval-later first tick means a deploy
  # defers the day's alerts by a full hour.
  @startup_delay_ms 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    case interval_ms() do
      0 ->
        Logger.info("FleetHealth.Alerter: disabled")

      interval ->
        Logger.info("FleetHealth.Alerter: checking every #{div(interval, 60_000)}m")
        Process.send_after(self(), :check, min(@startup_delay_ms, interval))
    end

    {:ok, %{alerted: %{}}}
  end

  @impl true
  def handle_info(:check, state) do
    state = run_check(state)
    Process.send_after(self(), :check, interval_ms())
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @doc "Runs the check immediately, ignoring the schedule. Handy from a console."
  def check_now, do: GenServer.call(__MODULE__, :check_now, 30_000)

  @impl true
  def handle_call(:check_now, _from, state) do
    state = run_check(state)
    {:reply, :ok, state}
  end

  defp run_check(state) do
    today = Date.utc_today()

    fresh = unalerted(FleetHealth.problems(), today)

    credits = credit_warning()
    credits_fresh? = credits != nil and Map.get(state.alerted, :openrouter) != today

    if fresh != [] or credits_fresh? do
      case Alerts.notify_admins(message(fresh, credits_fresh? && credits)) do
        :ok ->
          Enum.each(fresh, &Usage.record(&1.poet.user_id, "fleet_alert"))
          Logger.warning("FleetHealth.Alerter: alerted on #{length(fresh)} poet(s)")

        {:error, reason} ->
          Logger.warning("FleetHealth.Alerter: could not deliver alert: #{inspect(reason)}")
      end
    end

    alerted =
      if credits_fresh?, do: Map.put(state.alerted, :openrouter, today), else: state.alerted

    %{state | alerted: alerted}
  end

  @doc "The problem rows not yet reported today, by the `fleet_alert` rows."
  def unalerted(rows, today \\ Date.utc_today()),
    do: Enum.reject(rows, &alerted_today?(&1.poet.user_id, today))

  defp alerted_today?(user_id, today) do
    start = DateTime.new!(today, ~T[00:00:00], "Etc/UTC")

    UsageEvent
    |> where(user_id: ^user_id, kind: "fleet_alert")
    |> where([e], e.occurred_at >= ^start)
    |> Repo.exists?()
  end

  # The budget behind every poet. Worth its own line in the alert: when this is
  # the cause, no amount of retrying helps until someone tops the key up.
  defp credit_warning do
    case OpenRouter.key_status() do
      {:ok, %{exhausted?: true} = s} ->
        "OpenRouter key is OUT of credit (#{money(s.usage)} of #{money(s.limit)} used) — " <>
          "every model turn is being rejected with a 402 before it starts."

      {:ok, %{low?: true} = s} ->
        "OpenRouter key is nearly spent: #{money(s.remaining)} left of #{money(s.limit)}."

      _ ->
        nil
    end
  end

  defp money(nil), do: "?"
  defp money(n), do: "$#{:erlang.float_to_binary(n, decimals: 2)}"

  defp message(rows, credits) do
    header =
      case length(rows) do
        0 -> "⚠️ Traveling Poet: the fleet's budget needs attention"
        1 -> "⚠️ Traveling Poet: a poet has missed its day"
        n -> "⚠️ Traveling Poet: #{n} poets have missed their day"
      end

    [
      header,
      rows != [] && Enum.map_join(rows, "\n", &("• " <> FleetHealth.summarize(&1))),
      credits && "💳 #{credits}",
      "Full status: #{Alerts.admin_url()}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join("\n\n")
  end

  defp interval_ms do
    Application.get_env(:traveling_poet, :fleet_health_check_interval_minutes, 0) * 60_000
  end
end
