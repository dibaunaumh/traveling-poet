defmodule TravelingPoet.Feedback.CadenceTest do
  @moduledoc "When the recommend question is due (card-137): day 7, then every 90 days, 30 days' rest after Not now."
  use ExUnit.Case, async: true

  alias TravelingPoet.Feedback.Cadence

  @now ~U[2026-10-26 12:00:00Z]

  defp facts(attrs),
    do: Map.merge(%{journey_day: 7, last_answered_at: nil, dismissed_at: nil}, attrs)

  defp days_ago(n), do: DateTime.add(@now, -n, :day)

  test "from the seventh page on" do
    refute Cadence.due?(facts(%{journey_day: 6}), @now)
    refute Cadence.due?(facts(%{journey_day: nil}), @now)
    assert Cadence.due?(facts(%{journey_day: 7}), @now)
    assert Cadence.due?(facts(%{journey_day: 40}), @now)
  end

  test "once answered, not again for 90 days" do
    refute Cadence.due?(facts(%{last_answered_at: days_ago(89)}), @now)
    assert Cadence.due?(facts(%{last_answered_at: days_ago(90)}), @now)
    # Rows store a NaiveDateTime in UTC
    refute Cadence.due?(facts(%{last_answered_at: DateTime.to_naive(days_ago(10))}), @now)
  end

  test "Not now rests it for 30 days" do
    refute Cadence.due?(facts(%{dismissed_at: days_ago(29)}), @now)
    assert Cadence.due?(facts(%{dismissed_at: days_ago(30)}), @now)
  end
end
