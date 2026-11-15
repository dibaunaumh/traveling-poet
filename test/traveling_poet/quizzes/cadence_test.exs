defmodule TravelingPoet.Quizzes.CadenceTest do
  use ExUnit.Case, async: true

  alias TravelingPoet.Quizzes.Cadence

  @today ~D[2026-11-16]

  defp facts(attrs),
    do: Map.merge(%{published: 30, last_quiz_on: nil, published_since_last: 0}, attrs)

  test "no quiz before there is a journey to ask about" do
    assert Cadence.due(facts(%{published: 13}), @today) == :no
    assert Cadence.due(facts(%{published: 14}), @today) == {:quiz, "first"}
  end

  test "then every three weeks, with a dozen new pages to draw on" do
    three_weeks_ago = Date.add(@today, -21)

    assert Cadence.due(
             facts(%{last_quiz_on: Date.add(@today, -20), published_since_last: 20}),
             @today
           ) ==
             :no

    assert Cadence.due(facts(%{last_quiz_on: three_weeks_ago, published_since_last: 11}), @today) ==
             :no

    assert Cadence.due(facts(%{last_quiz_on: three_weeks_ago, published_since_last: 12}), @today) ==
             {:quiz, "cadence"}
  end

  test "a poet that missed days waits for fresh pages, however long it has been" do
    assert Cadence.due(
             facts(%{last_quiz_on: Date.add(@today, -60), published_since_last: 5}),
             @today
           ) ==
             :no
  end
end
