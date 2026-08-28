defmodule TravelingPoet.DailyJourneyScheduler do
  @moduledoc """
  App-side driver for each poet's daily Travel/Process/Discover run. Sprites
  suspend ~20s after activity and cannot wake themselves, so the app must
  wake each sprite and fire the `/travel-and-journal` trigger (same pattern
  as alice-in-goals' TpmSyncScheduler).

  Tick interval: `:journey_check_interval_minutes` (env
  JOURNEY_CHECK_INTERVAL_MINUTES, 0/absent = disabled). Each tick selects
  poets that are due — active, provisioned, no successful run in ~22h, past
  their assigned publish hour — gates each on the user's daily budget, and
  runs them staggered so the fleet doesn't stampede.

  Retry semantics: max 2 attempts per day (attempt events in the usage
  ledger); a missed day is simply missed — the skill tells the poet to
  acknowledge gaps gracefully.
  """

  use GenServer
  require Logger

  import Ecto.Query

  alias TravelingPoet.{Credits, Accounts, AgentSession, Repo, Usage}
  alias TravelingPoet.Poets.Poet
  alias TravelingPoet.Usage.UsageEvent

  @trigger "/travel-and-journal"
  @stagger_ms 20_000
  # journal generation + illustration takes minutes: 8 rounds ≈ 12 min held awake
  @hold_awake_rounds 8
  @reply_timeout_ms 10 * 60 * 1000
  @max_attempts_per_day 2
  # a run "counts" for ~22h so drift doesn't skip days
  @min_hours_between_runs 22

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    case interval_ms() do
      0 ->
        Logger.info("DailyJourneyScheduler: disabled")

      interval ->
        Logger.info("DailyJourneyScheduler: checking every #{div(interval, 60_000)}m")
        Process.send_after(self(), :tick, interval)
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    poets = due_poets()

    if poets != [] do
      Logger.info("DailyJourneyScheduler: tick — #{length(poets)} poet(s) due")
    end

    poets
    |> Enum.with_index()
    |> Enum.each(fn {poet, i} ->
      Task.start(fn ->
        Process.sleep(i * @stagger_ms)
        run_poet(poet)
      end)
    end)

    Process.send_after(self(), :tick, interval_ms())
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @doc "Poets due for their daily run right now. Public for testability."
  def due_poets(now \\ DateTime.utc_now()) do
    Poet
    |> where(status: "active")
    |> Repo.all()
    |> Enum.filter(fn poet ->
      user = Accounts.get_user(poet.user_id)

      user != nil and user.sprite_provisioned and
        past_publish_hour?(poet, now) and
        not ran_recently?(user.id, now) and
        attempts_today(user.id, now) < @max_attempts_per_day
    end)
  end

  defp run_poet(poet) do
    user = Accounts.get_user(poet.user_id)

    case eligible(user, poet) do
      :ok ->
        do_run(user, poet)

      {:skip, reason} ->
        Logger.info("DailyJourneyScheduler: user #{user.id} #{reason} — skipping")
    end
  end

  @doc "Whether a daily run may start now: daily caps, then credits."
  def eligible(user, poet) do
    cond do
      not Usage.within_budget?(user, "daily_run") -> {:skip, "over budget"}
      not Credits.can_run?(user, poet) -> {:skip, "out of credits"}
      true -> :ok
    end
  end

  defp do_run(user, poet) do
    Logger.info("DailyJourneyScheduler: running poet #{poet.id} (user #{user.id})")
    {:ok, attempt} = Usage.record(user.id, "daily_run_attempt")

    # Charge up front so a half-day balance can't buy a free run; refund
    # below when the run demonstrably failed.
    case Credits.debit_daily_run(user, poet, attempt.id) do
      {:ok, _} ->
        case AgentSession.run(user, @trigger,
               channel: "system",
               hold_awake_rounds: @hold_awake_rounds,
               reply_timeout_ms: @reply_timeout_ms
             ) do
          {:ok, reply} when reply != "" ->
            # Success = the agent finished its turn. (The publish API call is
            # the real outcome; this event closes the day either way so we
            # don't hammer a poet whose entry legitimately had no publish.)
            Usage.record(user.id, "daily_run")

          {:ok, ""} ->
            Logger.warning("DailyJourneyScheduler: poet #{poet.id} run timed out")
            Credits.refund_daily_run(user, attempt.id)

          {:error, reason} ->
            Logger.warning(
              "DailyJourneyScheduler: poet #{poet.id} run failed: #{inspect(reason)}"
            )

            Credits.refund_daily_run(user, attempt.id)
        end

      {:error, reason} ->
        Logger.warning(
          "DailyJourneyScheduler: poet #{poet.id} not charged (#{inspect(reason)}) — skipping"
        )
    end
  end

  # Each poet gets a stable pseudo-random publish hour (6:00–21:00 UTC by
  # default, or settings["journal_hour_utc"]) so the fleet spreads across the
  # day instead of stampeding at midnight.
  defp past_publish_hour?(poet, now) do
    hour =
      case Map.get(poet.settings || %{}, "journal_hour_utc") do
        h when is_integer(h) and h in 0..23 -> h
        _ -> 6 + rem(poet.id * 7, 16)
      end

    now.hour >= hour
  end

  defp ran_recently?(user_id, now) do
    cutoff = DateTime.add(now, -@min_hours_between_runs, :hour)

    UsageEvent
    |> where(user_id: ^user_id, kind: "daily_run")
    |> where([e], e.occurred_at >= ^cutoff)
    |> Repo.exists?()
  end

  defp attempts_today(user_id, now) do
    start_of_day = now |> DateTime.to_date() |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    UsageEvent
    |> where(user_id: ^user_id, kind: "daily_run_attempt")
    |> where([e], e.occurred_at >= ^start_of_day)
    |> select([e], count(e.id))
    |> Repo.one()
  end

  defp interval_ms do
    Application.get_env(:traveling_poet, :journey_check_interval_minutes, 0) * 60_000
  end
end
