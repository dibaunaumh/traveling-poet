defmodule TravelingPoet.Quizzes.Cadence do
  @moduledoc """
  When the poet spends a day quizzing its reader (dec-021: every ~3 weeks).
  Pure: the facts come in, a verdict goes out, so the rules are unit-tested
  and the poet never decides.

    * never before the #{14}th published page: a quiz needs a journey behind
      it to ask about;
    * then at most one every #{21} days, and only once #{12} new pages have
      gone out since the last one, so a quiz always has fresh pages to draw
      on (a poet that missed days does not quiz the same pages again).

  Which days can be quiz days at all (not a move day, not after an
  excursion, not when the stay guide is due) is the travel plan's call
  (`Poets.travel_plan/2`); this only says whether one is due.
  """

  @min_published 14
  @every_days 21
  @min_new_pages 12

  @type facts :: %{
          published: non_neg_integer(),
          last_quiz_on: Date.t() | nil,
          published_since_last: non_neg_integer()
        }

  def min_published, do: @min_published

  @doc "`{:quiz, reason}` when a quiz is due today, else `:no`."
  def due(%{published: published} = facts, %Date{} = today) do
    cond do
      published < @min_published -> :no
      is_nil(facts.last_quiz_on) -> {:quiz, "first"}
      Date.diff(today, facts.last_quiz_on) < @every_days -> :no
      facts.published_since_last < @min_new_pages -> :no
      true -> {:quiz, "cadence"}
    end
  end
end
