defmodule TravelingPoet.ItineraryTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.Poets
  alias TravelingPoet.Poets.Poet

  setup do
    user = user_fixture()
    poet = poet_fixture(user, %{settings: %{"mode" => "scout"}})
    %{user: user, poet: poet}
  end

  test "mode helper defaults to wander and honors scout", %{poet: poet} do
    assert Poet.mode(poet) == "scout"
    assert Poet.mode(%Poet{settings: %{}}) == "wander"
    assert Poet.mode(%Poet{settings: nil}) == "wander"
  end

  test "stops append in order, advance, and mark visited", %{poet: poet} do
    {:ok, s1} = Poets.add_stop(poet.id, %{place_name: "Porto", lat: 41.15, lng: -8.61})
    {:ok, s2} = Poets.add_stop(poet.id, %{place_name: "Coimbra", lat: 40.2, lng: -8.42})

    assert [%{position: 0}, %{position: 1}] = Poets.list_stops(poet.id)
    assert Poets.next_pending_stop(poet.id).id == s1.id

    {:ok, _} = Poets.mark_stop_visited(poet.id, s1.id)
    assert Poets.next_pending_stop(poet.id).id == s2.id

    {:ok, _} = Poets.mark_stop_visited(poet.id, s2.id)
    assert Poets.next_pending_stop(poet.id) == nil
  end

  test "remove_stop only removes the poet's own stops", %{poet: poet} do
    other = poet_fixture(user_fixture())
    {:ok, other_stop} = Poets.add_stop(other.id, %{place_name: "X", lat: 1.0, lng: 1.0})

    assert {:error, :not_found} = Poets.remove_stop(poet.id, other_stop.id)
    assert length(Poets.list_stops(other.id)) == 1
  end

  test "a hold keeps the poet in place through the date; release frees it", %{poet: poet} do
    {:ok, held} = Poets.hold(poet, 1, ~D[2026-09-09])
    assert held.hold_until == ~D[2026-09-10]
    assert Poets.held?(held, ~D[2026-09-10])
    refute Poets.held?(held, ~D[2026-09-11])

    {:ok, capped} = Poets.hold(poet, 99, ~D[2026-09-09])
    assert capped.hold_until == ~D[2026-10-09]

    {:ok, released} = Poets.release_hold(held)
    assert released.hold_until == nil
  end

  test "insert_stop_next puts a detour ahead of the next pending stop", %{poet: poet} do
    {:ok, s1} = Poets.add_stop(poet.id, %{place_name: "Porto", lat: 41.15, lng: -8.61})
    {:ok, _s2} = Poets.add_stop(poet.id, %{place_name: "Coimbra", lat: 40.2, lng: -8.42})
    {:ok, _} = Poets.mark_stop_visited(poet.id, s1.id)

    {:ok, detour} =
      Poets.insert_stop_next(poet.id, %{place_name: "Aveiro", lat: 40.64, lng: -8.65})

    assert detour.source == "chat"

    assert Enum.map(Poets.list_stops(poet.id), &{&1.place_name, &1.position}) ==
             [{"Porto", 0}, {"Aveiro", 1}, {"Coimbra", 2}]

    assert Poets.next_pending_stop(poet.id).id == detour.id
  end

  test "travel_plan: stay length, the route's end, a hold, and a detour", %{poet: poet} do
    five_days_ago = DateTime.add(DateTime.utc_now(), -5, :day)
    {:ok, poet} = Poets.update_poet(poet, %{arrived_at: five_days_ago})

    assert %{travel_today: false, reason: reason} = Poets.travel_plan(poet)
    assert reason =~ "itinerary complete"

    {:ok, s1} = Poets.add_stop(poet.id, %{place_name: "Porto", lat: 41.15, lng: -8.61})
    assert %{travel_today: true, destination: %{id: id}} = Poets.travel_plan(poet)
    assert id == s1.id

    {:ok, held} = Poets.hold(poet, 2)
    assert %{travel_today: false, reason: reason} = Poets.travel_plan(held)
    assert reason =~ "asked you to stay"

    {:ok, fresh} = Poets.update_poet(poet, %{arrived_at: DateTime.utc_now(), hold_until: nil})
    assert %{travel_today: false, reason: reason} = Poets.travel_plan(fresh)
    assert reason =~ "day 1 of 3"

    # a detour asked for in chat goes as soon as the poet is not held
    {:ok, _} = Poets.insert_stop_next(fresh.id, %{place_name: "Aveiro", lat: 40.64, lng: -8.65})
    assert %{travel_today: true, destination: %{place_name: "Aveiro"}} = Poets.travel_plan(fresh)
  end

  test "a wandering poet ignores the settings itinerary but goes where chat sent it" do
    user = user_fixture()
    five_days_ago = DateTime.add(DateTime.utc_now(), -5, :day)
    poet = poet_fixture(user, %{arrived_at: five_days_ago})

    {:ok, _} = Poets.add_stop(poet.id, %{place_name: "Porto", lat: 41.15, lng: -8.61})
    assert %{travel_today: true, destination: nil} = Poets.travel_plan(poet)

    {:ok, _} = Poets.insert_stop_next(poet.id, %{place_name: "Aveiro", lat: 40.64, lng: -8.65})
    assert %{travel_today: true, destination: %{place_name: "Aveiro"}} = Poets.travel_plan(poet)
  end

  test "poet_model policy: override beats scout beats fleet default" do
    alias TravelingPoet.Provisioner

    wander = %Poet{settings: %{}}
    scout = %Poet{settings: %{"mode" => "scout"}}
    override = %Poet{settings: %{"mode" => "scout", "model" => "custom/model-x"}}

    scout_model = Application.get_env(:traveling_poet, :scout_model)

    assert Provisioner.poet_model(wander) == Provisioner.openrouter_model()
    assert Provisioner.poet_model(scout) == scout_model
    assert Provisioner.poet_model(override) == "custom/model-x"
    assert Provisioner.poet_model(nil) == Provisioner.openrouter_model()

    # The precedence only means something while the two differ — config/runtime
    # pins them apart in test so this can't quietly become a tautology.
    refute scout_model == Provisioner.openrouter_model()
  end
end
