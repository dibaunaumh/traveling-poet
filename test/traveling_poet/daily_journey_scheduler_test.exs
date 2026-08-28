defmodule TravelingPoet.DailyJourneySchedulerTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{DailyJourneyScheduler, Usage}

  test "a run needs both the daily cap and enough credits" do
    user = user_fixture(%{credits: 1})
    poet = poet_fixture(user)
    assert DailyJourneyScheduler.eligible(user, poet) == :ok

    {:ok, _} = TravelingPoet.Poets.update_poet(poet, %{settings: %{"mode" => "scout"}})
    scout = TravelingPoet.Poets.get_poet_by_user(user.id)
    assert DailyJourneyScheduler.eligible(user, scout) == {:skip, "out of credits"}

    {:ok, _} = Usage.record(user.id, "daily_run")
    assert DailyJourneyScheduler.eligible(user, poet) == {:skip, "over budget"}
  end

  test "exempt users are always eligible on credits" do
    user = user_fixture(%{quota_exempt: true})
    poet = poet_fixture(user)
    assert DailyJourneyScheduler.eligible(user, poet) == :ok
  end
end
