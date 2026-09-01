defmodule TravelingPoet.FleetHealth.Alerter do
  @moduledoc """
  Watches `TravelingPoet.FleetHealth` and reports missed days over Telegram,
  so a silent fleet doesn't stay silent until someone happens to open the
  landing page.

  Checks hourly (`:fleet_health_check_interval_minutes`, env
  FLEET_HEALTH_CHECK_INTERVAL_MINUTES; 0/absent disables). Each poet is
  reported at most once per UTC day — a fleet-wide outage is one message a
  day, not one an hour. Dedup state lives in the process, so a deploy may
  re-send the day's alert; that beats persisting a table for it.

  Recipients: `:alert_telegram_chat_id` (env ALERT_TELEGRAM_CHAT_ID) when set,
  otherwise every admin who has paired Telegram.
  """

  use GenServer
  require Logger

  alias TravelingPoet.Accounts.User
  alias TravelingPoet.{FleetHealth, OpenRouter, Repo}
  alias TravelingPoet.Telegram.Client

  import Ecto.Query

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

    fresh =
      FleetHealth.problems()
      |> Enum.reject(fn row -> Map.get(state.alerted, row.poet.id) == today end)

    credits = credit_warning()
    credits_fresh? = credits != nil and Map.get(state.alerted, :openrouter) != today

    if fresh != [] or credits_fresh? do
      case deliver(message(fresh, credits_fresh? && credits)) do
        :ok ->
          Logger.warning("FleetHealth.Alerter: alerted on #{length(fresh)} poet(s)")

        {:error, reason} ->
          Logger.warning("FleetHealth.Alerter: could not deliver alert: #{inspect(reason)}")
      end
    end

    alerted = Enum.reduce(fresh, state.alerted, &Map.put(&2, &1.poet.id, today))
    alerted = if credits_fresh?, do: Map.put(alerted, :openrouter, today), else: alerted
    %{state | alerted: alerted}
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
      "Full status: #{admin_url()}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join("\n\n")
  end

  defp deliver(text) do
    case recipients() do
      [] ->
        {:error, :no_recipients}

      chat_ids ->
        Enum.reduce_while(chat_ids, :ok, fn chat_id, _acc ->
          case Client.send_message(chat_id, text, disable_web_page_preview: true) do
            :ok -> {:cont, :ok}
            err -> {:halt, err}
          end
        end)
    end
  end

  defp recipients do
    case Application.get_env(:traveling_poet, :alert_telegram_chat_id) do
      nil -> admin_chat_ids()
      "" -> admin_chat_ids()
      chat_id -> [chat_id]
    end
  end

  defp admin_chat_ids do
    User
    |> where([u], u.is_admin == true and not is_nil(u.telegram_chat_id))
    |> select([u], u.telegram_chat_id)
    |> Repo.all()
  end

  defp admin_url do
    base = Application.get_env(:traveling_poet, :phoenix_url, "https://poet.travel")
    String.trim_trailing(base, "/") <> "/admin"
  end

  defp interval_ms do
    Application.get_env(:traveling_poet, :fleet_health_check_interval_minutes, 0) * 60_000
  end
end
