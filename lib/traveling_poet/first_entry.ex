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

  alias TravelingPoet.{Accounts, AgentSession, Journal, Poets, Repo, Usage}
  alias TravelingPoet.Poets.Poet
  alias TravelingPoet.Usage.UsageEvent

  @trigger "/onboard"
  @attempt_kind "first_entry_attempt"
  @reply_timeout_ms 10 * 60 * 1000
  @max_attempts 3
  @retry_after_minutes 15

  def max_attempts, do: @max_attempts
  def retry_after_minutes, do: @retry_after_minutes

  @doc """
  Starts the first-entry run for this user unless one is already in flight,
  already done, or out of attempts. Safe to call repeatedly — the LiveView
  calls it on every gateway connect and the watchdog on every tick.

  Returns `:started | :done | :in_flight | :exhausted | :not_ready`.
  """
  def ensure_started(user, poet, now \\ DateTime.utc_now())

  def ensure_started(nil, _poet, _now), do: :not_ready
  def ensure_started(_user, nil, _now), do: :not_ready

  def ensure_started(user, poet, now) do
    cond do
      not user.sprite_provisioned ->
        :not_ready

      published?(poet) ->
        :done

      recent_attempt?(user.id, now) ->
        :in_flight

      attempts(user.id) >= @max_attempts ->
        :exhausted

      true ->
        {:ok, _} = Usage.record(user.id, @attempt_kind)
        Task.start(fn -> run(user, poet) end)
        :started
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
          attempts(user.id) < @max_attempts and not recent_attempt?(user.id, now)
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
      Logger.warning(
        "FirstEntry: user #{user.id} finished onboard without publishing " <>
          "(attempt #{attempts(user.id)} of #{@max_attempts})"
      )

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

  # One run holds the sprite awake for minutes; don't stack another on top.
  defp recent_attempt?(user_id, now) do
    cutoff = DateTime.add(now, -@retry_after_minutes, :minute)

    UsageEvent
    |> where(user_id: ^user_id, kind: @attempt_kind)
    |> where([e], e.occurred_at >= ^cutoff)
    |> Repo.exists?()
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
