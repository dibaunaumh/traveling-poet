defmodule TravelingPoet.NearHome.CadenceTest do
  use ExUnit.Case, async: true

  alias TravelingPoet.NearHome.Cadence

  # 2026-10-22 is a Thursday, 2026-10-19 a Monday.
  @thursday ~D[2026-10-22]
  @monday ~D[2026-10-19]

  defp facts(last, overrides \\ %{}),
    do: Map.merge(%{home?: true, enabled?: true, last_batch_on: last}, overrides)

  test "the first batch comes on the first day after a home is set, whatever the weekday" do
    assert Cadence.due?(facts(nil), @monday)
    assert Cadence.due?(facts(nil), @thursday)
  end

  test "never without a home, and never when the reader turned it off" do
    refute Cadence.due?(facts(nil, %{home?: false}), @thursday)
    refute Cadence.due?(facts(nil, %{enabled?: false}), @thursday)
    refute Cadence.due?(facts(~D[2026-10-01], %{enabled?: false}), @thursday)
  end

  test "weekly, late in the week so the picks land before the weekend" do
    assert Cadence.due?(facts(~D[2026-10-15]), @thursday)
    assert Cadence.due?(facts(~D[2026-10-15]), ~D[2026-10-23])
    refute Cadence.due?(facts(~D[2026-10-16]), @thursday), "six days is not a week"
    # A week has passed, but Saturday to Tuesday wait for Wednesday.
    refute Cadence.due?(facts(~D[2026-10-12]), @monday)
    refute Cadence.due?(facts(~D[2026-10-17]), ~D[2026-10-24])
  end

  test "a week whose late days were missed is caught up after ten days, on any day" do
    assert Cadence.due?(facts(~D[2026-10-09]), @monday)
    refute Cadence.due?(facts(~D[2026-10-10]), @monday)
  end
end
