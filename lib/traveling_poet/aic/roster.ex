defmodule TravelingPoet.AiC.Roster do
  @moduledoc """
  Who is expected to publish today, told to Alice-in-Context ahead of the hour.

  Without it the fleet's day shows only the poets that did something: a poet
  that never ran looks the same as a poet that was never due. Each poet that
  has set out gets one `expected` event a day, with the time it is due and
  whether it can run at all (paused, out of credits); the event is sent again
  when that changes. A poet that was due and published nothing is then a
  failure the reader of the twin can see, not an absence.
  """

  import Ecto.Query

  alias TravelingPoet.{Accounts, AiC, Credits, DailyJourneyScheduler, Journal, Poets, Repo}
  alias TravelingPoet.Poets.Poet

  @milli 1000

  @doc """
  Today's roster: `{poet, entry}` for every poet that has set out and whose
  reader has a sprite. `entry` is `%{date, due_at, status, reason, credits}`;
  `credits` is nil for an exempt account.
  """
  def entries(now \\ DateTime.utc_now()) do
    today = DateTime.to_date(now)

    Poet
    |> where([p], p.status in ["active", "paused", "error"])
    |> order_by(:id)
    |> Repo.all()
    |> Enum.flat_map(fn poet ->
      user = Accounts.get_user(poet.user_id)
      latest = Journal.latest_published_entry(poet.id)

      if user != nil and user.sprite_provisioned and latest != nil do
        {status, reason} = status(poet, user, latest.entry_date == today)

        [
          {poet,
           %{
             date: today,
             due_at: DailyJourneyScheduler.due_at(poet, now),
             status: status,
             reason: reason,
             credits: credits(user)
           }}
        ]
      else
        []
      end
    end)
  end

  @doc """
  Sends the roster entries that changed since `seen` (`%{poet_id => {date,
  status}}`, kept by the scheduler between ticks) and returns the new map.
  Does nothing, and asks the database nothing, when AiC is not configured.
  """
  def announce(seen, now \\ DateTime.utc_now()) do
    if AliceInContext.enabled?() do
      Map.new(entries(now), fn {poet, entry} ->
        key = {entry.date, entry.status}
        if Map.get(seen, poet.id) != key, do: AiC.expected(poet, entry)
        {poet.id, key}
      end)
    else
      seen
    end
  end

  # A page already out settles the day, whatever the poet's state is now.
  defp status(_poet, _user, true), do: {"due", nil}
  defp status(%Poet{status: "paused"}, _user, _published?), do: {"paused", "paused"}
  defp status(%Poet{status: "error"}, _user, _published?), do: {"paused", "in an error state"}

  defp status(poet, user, _published?) do
    if Credits.can_run?(user, poet, scouting: Poets.scouting?(poet)),
      do: {"due", nil},
      else: {"no_credits", "out of credits"}
  end

  defp credits(%{quota_exempt: true}), do: nil
  defp credits(user), do: Float.round(Credits.balance(user) / @milli, 1)
end
