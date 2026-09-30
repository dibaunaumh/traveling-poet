defmodule TravelingPoet.FirstEntry do
  @moduledoc """
  Gets a brand-new poet to publish its first journal entry.

  Agents don't start conversations on their own, so something has to fire
  `/onboard` at a freshly provisioned sprite. That used to happen in one place
  only: the journal LiveView, when the gateway reported `:connected` to a tab
  the user still had open. Two poets out of eight never got a first entry from
  it — theirs arrived with the next day's scheduled run, 9.8 and 8.8 hours
  later — while the setting-up screen said "you can safely close it; the poet
  keeps working", which was exactly the thing that wasn't true.

  So the kickoff moved server-side and became outcome-based:

    * it runs through `AgentSession`, like the daily run, so no browser needs
      to be open,
    * `agent_onboarded_at` is stamped when the agent's turn actually
      COMPLETES, not when the message is sent — a stamp on send meant one
      failed attempt marked a user onboarded forever,
    * a poet with no published entry stays pending and is retried, up to
      `max_attempts/0`, spaced by `retry_after_minutes/0`.

  `TravelingPoet.FirstEntry.Watchdog` drives the retries; the LiveView still
  calls `ensure_started/2` on connect so a watching user gets the fast path.
  """

  require Logger

  import Ecto.Query

  alias TravelingPoet.{Accounts, AgentSession, Journal, Poets, Provisioner, Repo, Usage}
  alias TravelingPoet.Poets.Poet
  alias TravelingPoet.Usage.UsageEvent

  @trigger "/onboard"
  @attempt_kind "first_entry_attempt"
  @reply_timeout_ms 10 * 60 * 1000
  @failed_kind "first_entry_failed"
  @max_attempts 3
  # A new reader may be watching: retry soon after an attempt ends without a
  # page. An attempt that never reports back counts as over after the second
  # figure (a healthy first page takes 5-10 minutes).
  @retry_after_minutes 5
  @stale_attempt_minutes 20

  def max_attempts, do: @max_attempts
  def retry_after_minutes, do: @retry_after_minutes
  def stale_attempt_minutes, do: @stale_attempt_minutes

  @doc """
  Starts the first-entry run for this user unless one is already in flight,
  already done, or out of attempts. Safe to call repeatedly — the LiveView
  calls it on every gateway connect and the watchdog on every tick.

  Returns `:started | :done | :in_flight | :exhausted | :not_ready`.
  """
  def ensure_started(user, poet, now \\ DateTime.utc_now()) do
    case status(user, poet, now) do
      :waiting_for_sprite ->
        :not_ready

      :retry_pending = state ->
        if cooling?(user.id, now), do: state, else: start(user, poet, state)

      :starting = state ->
        start(user, poet, state)

      state ->
        state
    end
  end

  defp start(user, poet, state) do
    {:ok, _} = Usage.record(user.id, @attempt_kind)

    Task.start(fn ->
      if state == :retry_pending, do: fresh_start(user)
      run(user, poet)
    end)

    :started
  end

  @doc """
  Where the first entry stands, for the journal placeholder. A pure read of
  the same facts `ensure_started/3` decides on, so the two can never disagree:

    * `:waiting_for_sprite` - no sprite yet, nothing can run
    * `:starting` - sprite ready, no attempt made yet
    * `:in_flight` - an attempt is running: no outcome yet, younger than `stale_attempt_minutes/0`
    * `:retry_pending` - the last attempt produced no page; retried `retry_after_minutes/0` after it ended
    * `:exhausted` - out of attempts; the daily run is the next chance
    * `:done` - a published entry exists
  """
  def status(user, poet, now \\ DateTime.utc_now())

  def status(nil, _poet, _now), do: :waiting_for_sprite
  def status(_user, nil, _now), do: :waiting_for_sprite

  def status(user, poet, now) do
    cond do
      not user.sprite_provisioned -> :waiting_for_sprite
      published?(poet) -> :done
      running?(user.id, now) -> :in_flight
      attempts(user.id) >= @max_attempts -> :exhausted
      attempts(user.id) == 0 -> :starting
      true -> :retry_pending
    end
  end

  @doc """
  Fires `/onboard` and waits for the turn. Stamps `agent_onboarded_at` only
  when the agent finished; leaves the poet pending when it didn't, so the
  watchdog picks it up again.
  """
  def run(user, poet) do
    started_at = DateTime.utc_now() |> DateTime.truncate(:second)
    Logger.info("FirstEntry: firing #{@trigger} for user #{user.id} (poet #{poet.id})")

    case AgentSession.run(user, @trigger,
           channel: "system",
           reply_timeout_ms: @reply_timeout_ms
         ) do
      {:ok, _reply} ->
        mark_awake(user)
        report(user, poet, started_at)

      {:timeout, _partial} ->
        Logger.warning("FirstEntry: user #{user.id} went silent mid-onboard — will retry")
        report(user, poet, started_at)

      {:error, reason} ->
        Logger.warning("FirstEntry: user #{user.id} onboard failed: #{inspect(reason)}")

        TravelingPoet.Alerts.notify_admins(
          "#{poet.name}'s first page failed to start: #{inspect(reason)}"
        )

        failed(user)
        :failed
    end
  end

  @doc """
  Poets still waiting for their first entry: provisioned, active, nothing
  published, and not yet out of attempts.
  """
  def pending(now \\ DateTime.utc_now()) do
    Poet
    # `sprite_provisioned` is the real gate — provisioning flips the poet to
    # "active" in a separate write, and a poet left on "provisioning" by a
    # failed status update has a perfectly good sprite and no first entry.
    # Paused and errored poets stay out.
    |> where([p], p.status in ["active", "provisioning"])
    |> Repo.all()
    |> Enum.map(fn poet -> {Accounts.get_user(poet.user_id), poet} end)
    |> Enum.filter(fn
      {nil, _poet} ->
        false

      {user, poet} ->
        user.sprite_provisioned and not published?(poet) and
          attempts(user.id) < @max_attempts and not running?(user.id, now) and
          not cooling?(user.id, now)
    end)
  end

  @doc "Kicks off every pending poet. Called by the watchdog on its tick."
  def sweep(now \\ DateTime.utc_now()) do
    pending(now)
    |> Enum.map(fn {user, poet} ->
      {poet.name, ensure_started(user, poet, now)}
    end)
  end

  defp report(user, poet, started_at) do
    if Journal.published_since?(poet.id, started_at) do
      Logger.info("FirstEntry: user #{user.id} published their first entry")
      :published
    else
      n = attempts(user.id)

      Logger.warning(
        "FirstEntry: user #{user.id} finished onboard without publishing " <>
          "(attempt #{n} of #{@max_attempts})"
      )

      # A new reader is often watching this happen; the operator should know
      # before they do.
      TravelingPoet.Alerts.notify_admins(
        "#{poet.name}'s first page did not publish (attempt #{n} of #{@max_attempts}). " <>
          if(n < @max_attempts,
            do: "Retrying in #{@retry_after_minutes} minutes with a fresh conversation.",
            else: "No retries left."
          )
      )

      failed(user)
      :no_entry
    end
  end

  defp mark_awake(user) do
    if is_nil(user.agent_onboarded_at) do
      Accounts.update_user(user, %{agent_onboarded_at: DateTime.utc_now()})
    end
  end

  defp published?(poet), do: Journal.latest_published_entry(poet.id) != nil

  defp attempts(user_id) do
    UsageEvent
    |> where(user_id: ^user_id, kind: @attempt_kind)
    |> select([e], count(e.id))
    |> Repo.one()
  end

  # The latest attempt is still going: no outcome recorded since it started,
  # and not yet stale. One run holds the sprite awake for minutes; don't
  # stack another on top.
  defp running?(user_id, now) do
    case latest(user_id, @attempt_kind) do
      nil ->
        false

      started ->
        is_nil(latest_since(user_id, @failed_kind, started)) and
          DateTime.diff(now, started, :minute) < @stale_attempt_minutes
    end
  end

  # The latest attempt ended without a page a moment ago: wait a little.
  defp cooling?(user_id, now) do
    with %DateTime{} = started <- latest(user_id, @attempt_kind),
         %DateTime{} = failed <- latest_since(user_id, @failed_kind, started) do
      DateTime.diff(now, failed, :minute) < @retry_after_minutes
    else
      _ -> false
    end
  end

  defp latest(user_id, kind) do
    UsageEvent
    |> where(user_id: ^user_id, kind: ^kind)
    |> select([e], max(e.occurred_at))
    |> Repo.one()
  end

  defp latest_since(user_id, kind, since) do
    UsageEvent
    |> where(user_id: ^user_id, kind: ^kind)
    |> where([e], e.occurred_at >= ^since)
    |> select([e], max(e.occurred_at))
    |> Repo.one()
  end

  defp failed(user), do: Usage.record(user.id, @failed_kind)

  # A retry starts from a clean conversation, never on top of the attempt
  # that failed (see Provisioner.fresh_conversation/1). Off in test, where
  # there is no sprite to restart.
  defp fresh_start(user) do
    if Application.get_env(:traveling_poet, :first_entry_fresh_start, true) do
      case Provisioner.fresh_conversation(user) do
        :ok ->
          Logger.info("FirstEntry: fresh conversation for user #{user.id} before retrying")
          # the gateway takes a few seconds to take connections again
          Process.sleep(Application.get_env(:traveling_poet, :gateway_boot_ms, 10_000))

        other ->
          Logger.warning(
            "FirstEntry: fresh conversation failed for user #{user.id}: #{inspect(other)}"
          )
      end
    end
  end

  @doc "Convenience for a console: force a poet's first entry, ignoring the cap."
  def force(poet_id) do
    poet = Repo.get!(Poet, poet_id)
    user = Accounts.get_user(poet.user_id)
    {:ok, _} = Usage.record(user.id, @attempt_kind)
    Task.start(fn -> run(user, poet) end)
    :started
  end

  @doc false
  def poet_for(user), do: Poets.get_poet_by_user(user.id)
end
