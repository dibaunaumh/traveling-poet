defmodule TravelingPoet.Asks.Cadence do
  @moduledoc """
  When the poet asks its reader what they are into, and about what. Pure:
  the facts come in, a verdict goes out, so the rules are unit-tested and
  the poet never decides (told to ask "now and then", a model asks every
  time or never).

  Excursions only happen for active topics, and most readers never open
  Settings, so a reader with none is asked until they have one; then the
  poet learns their tastes one domain at a time (`Topic.domains/0`):

    * never before the 3rd published entry: let them meet the poet first;
    * never while an earlier ask is still open (asked, no reply yet, inside
      the reply window), and never twice in a day;
    * no active topics: the open question, weekly;
    * with a topic: weekly, about the next domain they were never asked
      about and have no taste in yet (music first), until each was asked
      once;
    * then a monthly check-in, counted from the last ask or the newest
      topic: about a domain still unknown (the one asked longest ago), or
      "anything new?" once every domain is known;
    * after 3 unanswered asks in a row, weekly becomes monthly: someone who
      never answers is not nagged every week.
  """

  alias TravelingPoet.Topics.Topic

  @min_published 3
  @weekly 7
  @monthly 30
  @give_up_after 3

  @typedoc """
  `asks` newest first, each `%{asked_on: Date, about: String, answered:
  boolean, open: boolean}` (`open`: no reply yet, still inside the reply
  window). `domains_known`: the domains of every topic they have, whatever
  its status (a paused taste is still known).
  """
  @type facts :: %{
          published: non_neg_integer(),
          active_topics: non_neg_integer(),
          newest_topic_on: Date.t() | nil,
          domains_known: [String.t()],
          asks: [map()]
        }

  @doc "`{:ask, reason, about}` when today is a day to ask, else `:no`."
  def due(%{published: published} = facts, %Date{} = today) do
    last = List.first(facts.asks)

    cond do
      published < @min_published -> :no
      last && last.open -> :no
      last && last.asked_on == today -> :no
      facts.active_topics == 0 -> weekly(facts, last, today, "no_topics", "topics")
      next = next_domain(facts) -> weekly(facts, last, today, "domain", next)
      true -> check_in(facts, last, today)
    end
  end

  defp weekly(facts, last, today, reason, about) do
    streak = facts.asks |> Enum.take_while(&(not &1.answered)) |> length()
    every = if streak >= @give_up_after, do: @monthly, else: @weekly

    if is_nil(last) or Date.diff(today, last.asked_on) >= every,
      do: {:ask, reason, about},
      else: :no
  end

  # The first domain in the asking order never asked about and not known.
  defp next_domain(facts) do
    asked = MapSet.new(facts.asks, & &1.about)
    Enum.find(Topic.domains(), &(&1 not in facts.domains_known and not MapSet.member?(asked, &1)))
  end

  defp check_in(facts, last, today) do
    since =
      [last && last.asked_on, facts.newest_topic_on]
      |> Enum.reject(&is_nil/1)
      |> Enum.max(Date, fn -> nil end)

    if is_nil(since) or Date.diff(today, since) >= @monthly,
      do: {:ask, "check_in", stalest_unknown(facts) || "topics"},
      else: :no
  end

  # Of the domains still unknown (all asked once by now), the one asked
  # about longest ago comes back first.
  defp stalest_unknown(facts) do
    last_asked = facts.asks |> Enum.reverse() |> Map.new(&{&1.about, &1.asked_on})

    Topic.domains()
    |> Enum.reject(&(&1 in facts.domains_known))
    |> Enum.min_by(&Map.get(last_asked, &1, ~D[1970-01-01]), Date, fn -> nil end)
  end
end
