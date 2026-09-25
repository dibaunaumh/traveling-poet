defmodule TravelingPoet.AsksCadenceTest do
  use ExUnit.Case, async: true

  alias TravelingPoet.Asks.Cadence

  @today ~D[2026-10-01]

  defp facts(overrides) do
    Map.merge(%{published: 5, active_topics: 0, newest_topic_on: nil, asks: []}, overrides)
  end

  defp ask(days_ago, answered, open \\ false),
    do: %{asked_on: Date.add(@today, -days_ago), answered: answered, open: open}

  test "not before the third published entry" do
    assert Cadence.due(facts(%{published: 2}), @today) == :no
    assert Cadence.due(facts(%{published: 3}), @today) == {:ask, "no_topics"}
  end

  test "no topics: weekly after the last ask" do
    assert Cadence.due(facts(%{asks: [ask(6, true)]}), @today) == :no
    assert Cadence.due(facts(%{asks: [ask(7, true)]}), @today) == {:ask, "no_topics"}
  end

  test "never while an ask is still open, and never twice in a day" do
    assert Cadence.due(facts(%{asks: [ask(1, false, true)]}), @today) == :no
    assert Cadence.due(facts(%{asks: [ask(0, true)]}), @today) == :no
  end

  test "no topics: monthly once three asks in a row went unanswered" do
    two = [ask(7, false), ask(14, false), ask(21, true)]
    assert Cadence.due(facts(%{asks: two}), @today) == {:ask, "no_topics"}

    three = [ask(7, false), ask(14, false), ask(21, false)]
    assert Cadence.due(facts(%{asks: three}), @today) == :no

    assert Cadence.due(facts(%{asks: [ask(30, false) | tl(three)]}), @today) ==
             {:ask, "no_topics"}
  end

  test "with topics: a monthly check-in from the last ask or the newest topic" do
    base = %{active_topics: 2}

    assert Cadence.due(facts(Map.put(base, :asks, [ask(20, true)])), @today) == :no
    assert Cadence.due(facts(Map.put(base, :asks, [ask(30, true)])), @today) == {:ask, "check_in"}

    # a topic added last week counts as the last word on it
    recent = Map.merge(base, %{asks: [ask(40, true)], newest_topic_on: Date.add(@today, -7)})
    assert Cadence.due(facts(recent), @today) == :no

    old = Map.merge(base, %{newest_topic_on: Date.add(@today, -31)})
    assert Cadence.due(facts(old), @today) == {:ask, "check_in"}
  end
end
