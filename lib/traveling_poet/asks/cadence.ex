defmodule TravelingPoet.Asks.Cadence do
  @moduledoc """
  When the poet asks its reader what they are into. Pure: the facts come in,
  a verdict goes out, so the rules are unit-tested and the poet never
  decides (told to ask "now and then", a model asks every time or never).

  Excursions only happen for active topics, and most readers never open
  Settings, so a reader with none is asked until they have one:

    * never before the 3rd published entry: let them meet the poet first;
    * never while an earlier ask is still open (asked, no reply yet, inside
      the reply window), and never twice in a day;
    * no active topics: weekly, easing to monthly after 3 unanswered asks
      in a row (someone who never answers is not nagged every week);
    * with active topics: a light "anything new?" once a month, counted from
      the last ask or the newest topic, whichever is later.
  """

  @min_published 3
  @weekly 7
  @monthly 30
  @give_up_after 3

  @typedoc """
  `asks` newest first, each `%{asked_on: Date, answered: boolean, open: boolean}`
  (`open`: no reply yet and still inside the reply window).
  """
  @type facts :: %{
          published: non_neg_integer(),
          active_topics: non_neg_integer(),
          newest_topic_on: Date.t() | nil,
          asks: [map()]
        }

  @doc "`{:ask, reason}` when today is a day to ask, else `:no`."
  def due(%{published: published} = facts, %Date{} = today) do
    last = List.first(facts.asks)

    cond do
      published < @min_published -> :no
      last && last.open -> :no
      last && last.asked_on == today -> :no
      facts.active_topics == 0 -> no_topics(facts.asks, last, today)
      true -> check_in(facts, last, today)
    end
  end

  defp no_topics(asks, last, today) do
    streak = asks |> Enum.take_while(&(not &1.answered)) |> length()
    every = if streak >= @give_up_after, do: @monthly, else: @weekly

    if is_nil(last) or Date.diff(today, last.asked_on) >= every,
      do: {:ask, "no_topics"},
      else: :no
  end

  defp check_in(facts, last, today) do
    since =
      [last && last.asked_on, facts.newest_topic_on]
      |> Enum.reject(&is_nil/1)
      |> Enum.max(Date, fn -> nil end)

    if is_nil(since) or Date.diff(today, since) >= @monthly,
      do: {:ask, "check_in"},
      else: :no
  end
end
