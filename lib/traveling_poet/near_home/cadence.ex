defmodule TravelingPoet.NearHome.Cadence do
  @moduledoc """
  When the poet looks near home (card-71). Pure: the app decides, not the
  model.

  Weekly, and late in the week so the picks land before the weekend: due
  once seven days have passed and it is a Wednesday, Thursday or Friday. A
  week whose late days went by without a run (a paused poet, a failed day)
  is caught up on any day once ten days have passed. The first batch comes
  on the first published day after a home is set. Never without a home, and
  never when the reader turned it off.
  """

  @week 7
  @catch_up 10
  # Wednesday, Thursday, Friday (Date.day_of_week/1: Monday is 1)
  @late_week [3, 4, 5]

  @doc """
  `facts`: `%{home?: boolean, enabled?: boolean, last_batch_on: Date | nil}`.
  """
  def due?(%{home?: true, enabled?: true, last_batch_on: nil}, %Date{}), do: true

  def due?(%{home?: true, enabled?: true, last_batch_on: %Date{} = last}, %Date{} = today) do
    since = Date.diff(today, last)

    since >= @catch_up or (since >= @week and Date.day_of_week(today) in @late_week)
  end

  def due?(_facts, _today), do: false
end
