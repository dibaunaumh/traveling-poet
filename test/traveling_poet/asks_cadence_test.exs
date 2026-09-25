defmodule TravelingPoet.AsksCadenceTest do
  use ExUnit.Case, async: true

  alias TravelingPoet.Asks.Cadence

  @today ~D[2026-10-01]
  @all ~w(music books film_tv outdoors gifts)

  defp facts(overrides) do
    Map.merge(
      %{published: 5, active_topics: 0, newest_topic_on: nil, domains_known: [], asks: []},
      overrides
    )
  end

  defp ask(days_ago, answered, about \\ "topics", open \\ false),
    do: %{asked_on: Date.add(@today, -days_ago), about: about, answered: answered, open: open}

  test "not before the third published entry" do
    assert Cadence.due(facts(%{published: 2}), @today) == :no
    assert Cadence.due(facts(%{published: 3}), @today) == {:ask, "no_topics", "topics"}
  end

  test "no topics: weekly after the last ask" do
    assert Cadence.due(facts(%{asks: [ask(6, true)]}), @today) == :no
    assert Cadence.due(facts(%{asks: [ask(7, true)]}), @today) == {:ask, "no_topics", "topics"}
  end

  test "never while an ask is still open, and never twice in a day" do
    assert Cadence.due(facts(%{asks: [ask(1, false, "topics", true)]}), @today) == :no
    assert Cadence.due(facts(%{asks: [ask(0, true)]}), @today) == :no
  end

  test "monthly once three asks in a row went unanswered" do
    two = [ask(7, false), ask(14, false), ask(21, true)]
    assert Cadence.due(facts(%{asks: two}), @today) == {:ask, "no_topics", "topics"}

    three = [ask(7, false), ask(14, false), ask(21, false)]
    assert Cadence.due(facts(%{asks: three}), @today) == :no

    assert Cadence.due(facts(%{asks: [ask(30, false) | tl(three)]}), @today) ==
             {:ask, "no_topics", "topics"}
  end

  test "with a topic: one new domain a week, in order, skipping what is known" do
    base = %{active_topics: 1}

    assert Cadence.due(facts(Map.put(base, :asks, [ask(10, true)])), @today) ==
             {:ask, "domain", "music"}

    asked_music = Map.put(base, :asks, [ask(3, true, "music"), ask(10, true)])
    assert Cadence.due(facts(asked_music), @today) == :no

    week_later = Map.put(base, :asks, [ask(7, false, "music"), ask(14, true)])
    assert Cadence.due(facts(week_later), @today) == {:ask, "domain", "books"}

    # a music taste they typed in Settings is known: no need to ask
    known = Map.merge(base, %{domains_known: ["music", "books"]})
    assert Cadence.due(facts(known), @today) == {:ask, "domain", "film_tv"}
  end

  test "after every domain was asked once: a monthly check-in, unknown domains first" do
    asked = for {d, i} <- Enum.with_index(@all), do: ask(70 - i * 7, true, d)
    base = %{active_topics: 1, domains_known: ["music", "film_tv", "outdoors", "gifts"]}

    # books was asked longest ago of the unknown ones, and a month has passed
    assert Cadence.due(facts(Map.put(base, :asks, Enum.reverse(asked))), @today) ==
             {:ask, "check_in", "books"}

    recent = [ask(10, true, "gifts") | Enum.reverse(asked)]
    assert Cadence.due(facts(Map.put(base, :asks, recent)), @today) == :no

    everything = Map.merge(base, %{domains_known: @all, asks: Enum.reverse(asked)})
    assert Cadence.due(facts(everything), @today) == {:ask, "check_in", "topics"}

    # a topic added last week counts as the last word
    fresh = Map.put(everything, :newest_topic_on, Date.add(@today, -7))
    assert Cadence.due(facts(fresh), @today) == :no
  end
end
