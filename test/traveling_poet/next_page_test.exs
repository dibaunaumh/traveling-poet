defmodule TravelingPoet.NextPageTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{DailyJourneyScheduler, NextPage, Poets}

  setup do
    user = user_fixture()
    poet = poet_fixture(user, %{status: "active", settings: %{"journal_hour_utc" => 18}})
    %{poet: poet}
  end

  test "nothing before the first page", %{poet: poet} do
    assert NextPage.for(poet) == nil
  end

  test "today's page written: tomorrow at the poet's hour, from where it is", %{poet: poet} do
    now = ~U[2026-09-30 19:00:00Z]
    published_entry_fixture(poet, %{entry_date: ~D[2026-09-30]})

    next = NextPage.for(poet, now)
    assert next.at == ~U[2026-10-01 18:00:00Z]
    assert DailyJourneyScheduler.publish_hour(poet) == 18

    if next.moving? do
      assert next.place != "Lisbon, Portugal"
    else
      assert next.place == "Lisbon"
    end
  end

  test "today's page not yet written: today", %{poet: poet} do
    published_entry_fixture(poet, %{entry_date: ~D[2026-09-29]})
    assert NextPage.for(poet, ~U[2026-09-30 09:00:00Z]).at == ~U[2026-09-30 18:00:00Z]
  end

  test "a paused poet promises nothing", %{poet: poet} do
    published_entry_fixture(poet, %{entry_date: ~D[2026-09-30]})
    {:ok, poet} = Poets.update_poet(poet, %{status: "paused"})
    assert NextPage.for(poet) == nil
  end
end
