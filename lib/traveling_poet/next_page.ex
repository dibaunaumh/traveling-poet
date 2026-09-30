defmodule TravelingPoet.NextPage do
  @moduledoc """
  When and from where the reader's next page arrives, for the line under
  their latest page ("Next page: tomorrow around 8 PM, from Sintra"). A
  reader finishing a page had no idea when the next one came, so nothing
  brought them back (card-74).

  `at` is the poet's daily publish hour (`DailyJourneyScheduler.publish_hour/1`,
  UTC); the browser shows it in the reader's own time zone. `place` is where
  the poet is, or the stop it is heading for; nil on a travel day when the
  poet picks somewhere new itself.
  """

  alias TravelingPoet.{DailyJourneyScheduler, Journal, Poets}
  alias TravelingPoet.Poets.Poet

  @doc """
  `%{at: DateTime.t(), place: String.t() | nil, moving?: boolean}`, or nil for
  a poet that is not travelling (paused, or no first page yet).
  """
  def for(poet, now \\ DateTime.utc_now())

  def for(%Poet{status: "active"} = poet, now) do
    case Journal.latest_published_entry(poet.id) do
      nil ->
        nil

      latest ->
        today = DateTime.to_date(now)
        hour = DailyJourneyScheduler.publish_hour(poet)

        date =
          if Date.compare(latest.entry_date, today) == :lt, do: today, else: Date.add(today, 1)

        at = DateTime.new!(date, Time.new!(hour, 0, 0), "Etc/UTC")
        plan = Poets.travel_plan(poet, date)

        %{
          at: at,
          moving?: plan.travel_today,
          place:
            cond do
              not plan.travel_today -> short(poet.current_place_name)
              plan.destination -> short(plan.destination.place_name)
              true -> nil
            end
        }
    end
  end

  def for(_poet, _now), do: nil

  # "Sintra, Lisbon District, Portugal" reads as "Sintra".
  defp short(nil), do: nil
  defp short(name), do: name |> String.split(",") |> hd() |> String.trim()
end
