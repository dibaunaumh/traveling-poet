defmodule TravelingPoet.FleetHealth do
  @moduledoc """
  One question, asked of every poet: is it still publishing?

  The daily run has several ways to fail quietly — the sprite never replies,
  the agent narrates the ritual without calling `journal_publish`, the poet
  moves and then stalls before writing the new place up. All of them look the
  same from outside: the map moves on and the journal doesn't. This module is
  the detector, and `TravelingPoet.FleetHealth.Alerter` is the thing that
  says so out loud.

  `report/1` grades every poet; `problems/1` keeps the ones worth waking
  someone up for.
  """

  import Ecto.Query

  alias TravelingPoet.{Accounts, DailyJourneyScheduler, Journal, Repo}
  alias TravelingPoet.Poets.Poet
  alias TravelingPoet.Usage.UsageEvent

  # A poet publishes daily, so a gap past this is a missed day rather than a
  # late one — generous enough to survive publish-hour drift.
  @stale_hours 30

  @doc """
  Every poet, graded. Statuses:

    * `:ok` — published within #{@stale_hours}h
    * `:late` — overdue, but the scheduler still has attempts left today
    * `:failing` — overdue and out of attempts today: a missed day
    * `:never_published` — provisioned but has never published anything
    * `:inactive` — paused, or the sprite was never provisioned
  """
  def report(now \\ DateTime.utc_now()) do
    Poet
    |> Repo.all()
    |> Enum.map(&grade(&1, now))
    |> Enum.sort_by(&sort_key/1)
  end

  @doc "Only the poets in trouble — what an alert should talk about."
  def problems(now \\ DateTime.utc_now()) do
    report(now) |> Enum.filter(&(&1.status in [:failing, :never_published]))
  end

  @doc """
  Poets whose map pin has outrun their journal: the location says one place,
  the newest published entry says another. Usually transient (the poet moved
  an hour ago and writes tonight), so it is reported, not alerted on.
  """
  def drifted(now \\ DateTime.utc_now()) do
    report(now) |> Enum.filter(& &1.drifted?)
  end

  defp grade(poet, now) do
    user = Accounts.get_user(poet.user_id)
    latest = Journal.latest_published_entry(poet.id)
    hours = latest && DateTime.diff(now, latest.published_at, :second) / 3600
    attempts = attempts_today(poet.user_id, now)

    %{
      poet: poet,
      user: user,
      last_published_at: latest && latest.published_at,
      last_entry_date: latest && latest.entry_date,
      entry_place: latest && latest.place_name,
      current_place: poet.current_place_name,
      hours_since_publish: hours && Float.round(hours, 1),
      attempts_today: attempts,
      attempts_left: max(DailyJourneyScheduler.max_attempts_per_day() - attempts, 0),
      drifted?: drifted?(poet, latest),
      status: status(poet, user, hours, attempts)
    }
  end

  defp status(poet, user, hours, attempts) do
    cond do
      poet.status != "active" -> :inactive
      user == nil or not user.sprite_provisioned -> :inactive
      hours == nil -> :never_published
      hours <= @stale_hours -> :ok
      attempts < DailyJourneyScheduler.max_attempts_per_day() -> :late
      true -> :failing
    end
  end

  # Both places known and different — the symptom a reader actually notices.
  defp drifted?(_poet, nil), do: false
  defp drifted?(%{current_place_name: nil}, _entry), do: false
  defp drifted?(_poet, %{place_name: nil}), do: false
  defp drifted?(poet, entry), do: poet.current_place_name != entry.place_name

  defp attempts_today(user_id, now) do
    start_of_day = now |> DateTime.to_date() |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    UsageEvent
    |> where(user_id: ^user_id, kind: "daily_run_attempt")
    |> where([e], e.occurred_at >= ^start_of_day)
    |> select([e], count(e.id))
    |> Repo.one()
  end

  # Worst first, so the admin table opens on whatever needs attention.
  defp sort_key(%{status: status, hours_since_publish: hours}) do
    rank =
      case status do
        :failing -> 0
        :never_published -> 1
        :late -> 2
        :ok -> 3
        :inactive -> 4
      end

    {rank, -(hours || 0)}
  end

  @doc "Human-readable one-liner for a graded row — used by alerts."
  def summarize(row) do
    place = row.current_place || "nowhere yet"

    age =
      case row.hours_since_publish do
        nil -> "never published"
        h -> "last published #{trunc(h)}h ago"
      end

    "#{row.poet.name} (#{place}) — #{age}, #{row.attempts_today} attempt(s) today"
  end
end
