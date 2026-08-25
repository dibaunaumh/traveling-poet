defmodule TravelingPoet.UsageTest do
  use TravelingPoet.DataCase, async: true

  import TravelingPoet.Fixtures

  alias TravelingPoet.Usage

  test "budget gate blocks once daily cost cap is reached" do
    user = user_fixture(%{daily_budget_cents: 10})

    assert Usage.within_budget?(user, "chat_turn")

    # chat_turn ≈ 2¢ each: five of them hit the 10¢ budget
    for _ <- 1..5, do: {:ok, _} = Usage.record(user.id, "chat_turn")

    refute Usage.within_budget?(user, "chat_turn")
  end

  test "per-kind cap blocks independently of cost budget" do
    user = user_fixture(%{daily_budget_cents: 10_000})

    {:ok, _} = Usage.record(user.id, "daily_run")
    # daily_runs_cap defaults to 1
    refute Usage.within_budget?(user, "daily_run")
    assert Usage.within_budget?(user, "chat_turn")
  end

  test "quota_exempt users always pass" do
    user = user_fixture(%{daily_budget_cents: 0, quota_exempt: true})
    assert Usage.within_budget?(user, "daily_run")
  end
end
