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

  Retry semantics: max 3 attempts per day (attempt events in the usage
  ledger); a missed day is simply missed — the skill tells the poet to
  acknowledge gaps gracefully.

  A run counts as successful only when the poet actually PUBLISHED during it
  (see `finish_run/5`). An agent that narrates the ritual and never calls
  `journal_publish` leaves the reader with nothing, so it is refunded and
  retried rather than billed and closed out.
  """

  use GenServer
  require Logger

  import Ecto.Query

  alias TravelingPoet.{Credits, Accounts, AgentSession, Books, Journal, Poets, Repo, Usage}
  alias TravelingPoet.Poets.Poet
  alias TravelingPoet.Usage.UsageEvent

  @trigger "/travel-and-journal"
  @stagger_ms 20_000
  @reply_timeout_ms 10 * 60 * 1000
  @max_attempts_per_day 3
  # The first tick comes shortly after boot, not a full interval later.
  # Scheduling it an interval out means a deploy postpones every pending run by
  # the whole interval, so a day of frequent deploys can starve the fleet
  # indefinitely — and nothing alerts, because the poets only look "late".
  # Happened on 2026-08-31: three deploys inside 35 minutes pushed three poets'
  # runs back an hour and a half.
  @startup_delay_ms 60_000
  # a run "counts" for ~22h so drift doesn't skip days
  @min_hours_between_runs 22
  # How long an attempt may still be going on the sprite after it started: the
  # reply timeout plus room for the turn to finish publishing after the app
  # stopped listening. A deploy kills the Task that was waiting on the run,
  # but not the run itself; Hilma, 2026-09-16: a deploy two minutes into her
  # run, and the restarted scheduler sent a second /travel-and-journal into
  # the turn still in progress. No new attempt starts inside this window, and
  # attempts older than it with no recorded outcome are settled (see
  # settle_interrupted/1).
  @in_flight_minutes 20

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    case interval_ms() do
      0 ->
        Logger.info("DailyJourneyScheduler: disabled")

      interval ->
        Logger.info("DailyJourneyScheduler: checking every #{div(interval, 60_000)}m")
        Process.send_after(self(), :tick, min(@startup_delay_ms, interval))
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    settle_interrupted()
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

  @doc "How many times a poet's day may be attempted before it's a missed day."
  def max_attempts_per_day, do: @max_attempts_per_day

  @doc "Poets due for their daily run right now. Public for testability."
  def due_poets(now \\ DateTime.utc_now()) do
    Poet
    |> where(status: "active")
    |> Repo.all()
    |> Enum.filter(fn poet ->
      user = Accounts.get_user(poet.user_id)

      user != nil and user.sprite_provisioned and
        past_publish_hour?(poet, now) and
        not published_today?(poet, now) and
        not ran_recently?(user.id, now) and
        not revising?(user.id, now) and
        not attempt_in_flight?(user.id, now) and
        attempts_today(user.id, now) < @max_attempts_per_day
    end)
  end

  @doc """
  Runs one poet's day right now, ignoring the per-day attempt cap and the
  daily-run cap — for catching up after an outage that wasn't the poet's
  fault. Those caps exist to stop a broken agent burning money in a loop, not
  to block a deliberate retry, but credits are still checked: no run happens
  on an empty balance.

  Synchronous, and a full ritual takes minutes — call it from a Task (see
  `TravelingPoet.FleetHealth.catch_up/1`) rather than blocking a console on it.
  """
  def run_now(%Poet{} = poet) do
    case Accounts.get_user(poet.user_id) do
      nil ->
        {:error, :no_user}

      user ->
        if Credits.can_run?(user, poet) do
          do_run(user, poet)
          :ok
        else
          {:error, :out_of_credits}
        end
    end
  end

  def run_now(poet_id) when is_integer(poet_id), do: run_now(Repo.get!(Poet, poet_id))

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
      # the poet is writing its book in a long turn; two turns interleave
      Books.composing?(poet) -> {:skip, "composing its book"}
      true -> :ok
    end
  end

  defp do_run(user, poet) do
    Logger.info("DailyJourneyScheduler: running poet #{poet.id} (user #{user.id})")
    started_at = DateTime.utc_now() |> DateTime.truncate(:second)
    {:ok, attempt} = Usage.record(user.id, "daily_run_attempt")

    # Charge up front so a half-day balance can't buy a free run; refund
    # below when the run demonstrably failed. The day's kind goes on the
    # ledger row so admin can tell an excursion run from a travel run.
    day = Poets.travel_plan(poet).day

    case Credits.debit_daily_run(user, poet, attempt.id, day: day) do
      {:ok, _} ->
        outcome =
          AgentSession.run(user, @trigger,
            channel: "system",
            reply_timeout_ms: @reply_timeout_ms
          )

        finish_run(user, poet, attempt, started_at, outcome)

      {:error, reason} ->
        Logger.warning(
          "DailyJourneyScheduler: poet #{poet.id} not charged (#{inspect(reason)}) — skipping"
        )
    end
  end

  # The run's outcome is what reached the reader, not what the agent said.
  # An agent can move the poet, draw an illustration, narrate the whole ritual
  # and still never call journal_publish — that is a failed day, and billing it
  # as a success also suppresses the retry that would have saved it.
  defp finish_run(user, poet, attempt, started_at, outcome) do
    published? = Journal.published_since?(poet.id, started_at)

    # Publication settles the day, whatever the turn did afterwards. An error
    # branch that ignored this is what stranded Hilma on 2026-08-31: her entry
    # published at 21:16, her gateway socket dropped moments later, the run was
    # written off as failed, and the scheduler then retried a day that was
    # already done — the third retry moved her to a new city for nothing.
    if published? do
      log_published_outcome(poet, outcome)
      record_daily_run(user.id, attempt.id)
    else
      log_unpublished_outcome(poet, outcome)
      Credits.refund_daily_run(user, attempt.id)
    end
  end

  # The outcome row names its attempt, so an attempt without one can be told
  # apart later (settle_interrupted/1).
  defp record_daily_run(user_id, attempt_id, extra \\ %{}),
    do: Usage.record(user_id, "daily_run", %{metadata: Map.put(extra, "attempt_id", attempt_id)})

  @doc """
  Settles attempts whose Task died before finish_run (a deploy or crash mid
  run). Every attempt normally ends in exactly one of: a `daily_run` usage row
  (published) or a refund (not). An attempt past the in-flight window with
  neither is settled the same way finish_run would have: published since it
  started counts the day; otherwise the debit is refunded. Idempotent.
  Returns the number settled. Public so a test, or a console, can run one pass.
  """
  def settle_interrupted(now \\ DateTime.utc_now()) do
    in_flight_cutoff = DateTime.add(now, -@in_flight_minutes, :minute)
    oldest = DateTime.add(now, -1, :day)

    UsageEvent
    |> where(kind: "daily_run_attempt")
    |> where([e], e.occurred_at >= ^oldest and e.occurred_at < ^in_flight_cutoff)
    |> Repo.all()
    |> Enum.filter(&unsettled?/1)
    |> Enum.map(&settle/1)
    |> Enum.count(&(&1 != :skipped))
  end

  defp unsettled?(attempt) do
    window_end = DateTime.add(attempt.occurred_at, @in_flight_minutes, :minute)

    outcomes =
      UsageEvent
      |> where(user_id: ^attempt.user_id, kind: "daily_run")
      |> where([e], e.occurred_at >= ^attempt.occurred_at)
      |> Repo.all()

    # Settled by attempt id, or (rows from before ids were recorded) by a
    # daily_run inside the attempt's own window.
    by_id? = Enum.any?(outcomes, &(&1.metadata["attempt_id"] == attempt.id))

    by_window? =
      Enum.any?(outcomes, fn e ->
        is_nil(e.metadata["attempt_id"]) and DateTime.compare(e.occurred_at, window_end) != :gt
      end)

    not by_id? and not by_window? and not Credits.refunded_daily_run?(attempt.user_id, attempt.id)
  end

  defp settle(attempt) do
    with %{} = user <- Accounts.get_user(attempt.user_id),
         %Poet{} = poet <- Repo.get_by(Poet, user_id: user.id) do
      if Journal.published_since?(poet.id, attempt.occurred_at) do
        Logger.warning(
          "DailyJourneyScheduler: attempt #{attempt.id} for poet #{poet.id} was interrupted " <>
            "but published; counting the day"
        )

        record_daily_run(user.id, attempt.id, %{"settled" => true})
        :counted
      else
        # An exempt account was never charged: nothing to give back, and
        # nothing to log on every tick until the attempt ages out.
        case Credits.refund_daily_run(user, attempt.id) do
          {:ok, :nothing_to_refund} ->
            :skipped

          _ ->
            Logger.warning(
              "DailyJourneyScheduler: attempt #{attempt.id} for poet #{poet.id} was " <>
                "interrupted with nothing published; refunded"
            )

            :refunded
        end
      end
    else
      _ -> :skipped
    end
  end

  defp log_published_outcome(_poet, {:ok, _reply}), do: :ok

  defp log_published_outcome(poet, {:timeout, partial}) do
    # Stalled after publishing: the reader got their entry, so the day counts.
    # Only the chat sign-off was lost.
    Logger.warning(
      "DailyJourneyScheduler: poet #{poet.id} published then stalled " <>
        "(#{String.length(partial)} chars partial) — counting the day"
    )
  end

  defp log_published_outcome(poet, {:error, reason}) do
    Logger.warning(
      "DailyJourneyScheduler: poet #{poet.id} published, then the turn failed " <>
        "(#{inspect(reason)}) — counting the day anyway"
    )
  end

  defp log_unpublished_outcome(poet, {:ok, _reply}) do
    Logger.warning(
      "DailyJourneyScheduler: poet #{poet.id} finished its turn without publishing — " <>
        "refunding and leaving the day open for a retry"
    )
  end

  defp log_unpublished_outcome(poet, {:timeout, _partial}) do
    Logger.warning("DailyJourneyScheduler: poet #{poet.id} run timed out with nothing published")
  end

  defp log_unpublished_outcome(poet, {:error, reason}) do
    Logger.warning("DailyJourneyScheduler: poet #{poet.id} run failed: #{inspect(reason)}")
  end

  # Each poet gets a stable pseudo-random publish hour (6:00–21:00 UTC by
  # default, or settings["journal_hour_utc"]) so the fleet spreads across the
  # day instead of stampeding at midnight.
  @doc "The UTC hour this poet is expected to publish at. Public for FleetHealth."
  def publish_hour(poet) do
    case Map.get(poet.settings || %{}, "journal_hour_utc") do
      h when is_integer(h) and h in 0..23 -> h
      _ -> 6 + rem(poet.id * 7, 16)
    end
  end

  defp past_publish_hour?(poet, now), do: now.hour >= publish_hour(poet)

  # The reader having today's entry is the goal, so it is also the stopping
  # condition — independent of whether the usage ledger managed to record the
  # run. Re-running a published day doesn't just waste a run: the ritual starts
  # by travelling, so it moves the poet to a new city, and if it then wrote an
  # entry it would overwrite the one already published for that date.
  defp published_today?(poet, now) do
    case Journal.latest_published_entry(poet.id) do
      nil -> false
      entry -> entry.entry_date == DateTime.to_date(now)
    end
  end

  defp ran_recently?(user_id, now) do
    cutoff = DateTime.add(now, -@min_hours_between_runs, :hour)

    UsageEvent
    |> where(user_id: ^user_id, kind: "daily_run")
    |> where([e], e.occurred_at >= ^cutoff)
    |> Repo.exists?()
  end

  # A feedback revision holds the sprite in a turn for minutes; stacking the
  # daily run on top would interleave the two streams and burn an attempt.
  @revision_window_minutes 15

  defp revising?(user_id, now) do
    cutoff = DateTime.add(now, -@revision_window_minutes, :minute)

    UsageEvent
    |> where(user_id: ^user_id, kind: "marker_revision_attempt")
    |> where([e], e.occurred_at >= ^cutoff)
    |> Repo.exists?()
  end

  # A run started inside the in-flight window may still be going on the
  # sprite, even when the app lost track of it.
  defp attempt_in_flight?(user_id, now) do
    cutoff = DateTime.add(now, -@in_flight_minutes, :minute)

    UsageEvent
    |> where(user_id: ^user_id, kind: "daily_run_attempt")
    |> where([e], e.occurred_at > ^cutoff)
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
