defmodule TravelingPoet.Feedback.Cadence do
  @moduledoc """
  When the journal asks "would you recommend us" (card-137, Udi 2026-10-26):
  once the reader has a week of pages, then every 90 days. "Not now" rests
  the question for 30 days. Pure, so the timing is unit-tested; the journal
  adds the page rules (latest page, still fresh, nothing else asked beside it).
  """

  @from_day 7
  @every_days 90
  @rest_days 30

  def from_day, do: @from_day
  def every_days, do: @every_days
  def rest_days, do: @rest_days

  @doc """
  True when the question is due. `facts` has `journey_day` (the page's day,
  Day 1 = the first page), `last_answered_at` and `dismissed_at`, each a
  DateTime or nil.
  """
  def due?(facts, now \\ DateTime.utc_now()) do
    (facts.journey_day || 0) >= @from_day and
      rested?(facts.last_answered_at, @every_days, now) and
      rested?(facts.dismissed_at, @rest_days, now)
  end

  defp rested?(nil, _days, _now), do: true
  defp rested?(%DateTime{} = at, days, now), do: DateTime.diff(now, at, :day) >= days

  defp rested?(%NaiveDateTime{} = at, days, now),
    do: rested?(DateTime.from_naive!(at, "Etc/UTC"), days, now)
end
