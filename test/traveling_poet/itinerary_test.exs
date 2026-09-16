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

  describe "a scout's starting stop" do
    defp scout_at(place, lat, lng, arrived_days_ago) do
      at =
        DateTime.utc_now() |> DateTime.add(-arrived_days_ago, :day) |> DateTime.truncate(:second)

      poet_fixture(user_fixture(), %{
        settings: %{"mode" => "scout"},
        current_place_name: place,
        current_lat: lat,
        current_lng: lng,
        arrived_at: at
      })
    end

    test "the route chosen at signup starts visited at the first stop" do
      poet = scout_at("Chiang Mai, Thailand", 18.79, 98.99, 5)

      stops =
        Poets.start_itinerary(poet, [
          %{place_name: "Chiang Mai, Thailand", lat: 18.79, lng: 98.99, country_code: "TH"},
          %{place_name: "Da Nang, Vietnam", lat: 16.05, lng: 108.2, country_code: "VN"},
          %{place_name: "Fukuoka, Japan", lat: 33.59, lng: 130.4, country_code: "JP"}
        ])

      assert [{:ok, first}, {:ok, second}, {:ok, third}] = stops
      assert first.visited_at == poet.arrived_at
      assert is_nil(second.visited_at) and is_nil(third.visited_at)

      # the first stay is over: the poet goes on to Da Nang, not to Chiang Mai again
      assert %{travel_today: true, destination: %{place_name: "Da Nang, Vietnam"}} =
               Poets.travel_plan(poet)
    end

    test "a pending stop at the place the poet already is gets skipped, by name or distance" do
      # same city, different spelling from the geocoder
      poet = scout_at("京都市, 京都府, 日本", 35.0116, 135.7681, 5)
      {:ok, _} = Poets.add_stop(poet.id, %{place_name: "Kyoto, Japan", lat: 35.02, lng: 135.76})
      {:ok, nara} = Poets.add_stop(poet.id, %{place_name: "Nara, Japan", lat: 34.68, lng: 135.8})

      assert Poets.next_stop_to_travel(poet).id == nara.id
      assert %{destination: %{place_name: "Nara, Japan"}} = Poets.travel_plan(poet)

      # a later stop in the same city is not skipped: only the leading ones
      far = scout_at("Nara, Japan", 34.68, 135.8, 5)
      {:ok, osaka} = Poets.add_stop(far.id, %{place_name: "Osaka, Japan", lat: 34.69, lng: 135.5})
      {:ok, _} = Poets.add_stop(far.id, %{place_name: "Nara, Japan", lat: 34.68, lng: 135.8})
      assert Poets.next_stop_to_travel(far).id == osaka.id
    end
  end

  describe "travel_plan and excursions" do
    setup do
      user = user_fixture()
      one_day_ago = DateTime.add(DateTime.utc_now(), -1, :day)
      poet = poet_fixture(user, %{arrived_at: one_day_ago})
      topic = topic_fixture(poet, %{label: "Kit airplanes"})
      %{poet: poet, topic: topic}
    end

    test "a stay day with a topic due becomes an excursion; the poet does not move",
         %{poet: poet, topic: topic} do
      plan = Poets.travel_plan(poet)

      assert plan.day == "excursion"
      assert plan.travel_today == false
      assert plan.excursion.topic_id == topic.id
      assert plan.excursion.label == "Kit airplanes"
      assert plan.excursion.source == "app"
      assert plan.excursion.id == nil
      assert plan.reason =~ "excursion into Kit airplanes"
      # every key the skills already read is still there
      assert %{days_here: 1, stay_duration_days: 3, destination: nil, visited: []} = plan
    end

    test "a move day always wins over an excursion", %{poet: poet} do
      five_days_ago = DateTime.add(DateTime.utc_now(), -5, :day)
      {:ok, poet} = Poets.update_poet(poet, %{arrived_at: five_days_ago})

      assert %{day: "move", travel_today: true, excursion: nil} = Poets.travel_plan(poet)
    end

    test "never two excursion days in a row", %{poet: poet, topic: topic} do
      yesterday = Date.add(Date.utc_today(), -1)
      entry = published_entry_fixture(poet, %{entry_date: yesterday})
      excursion_fixture(poet, topic, entry)

      assert %{day: "stay", travel_today: false, excursion: nil} = Poets.travel_plan(poet)
    end

    test "a chat request goes before the cadence, and names what was asked for",
         %{poet: poet, topic: topic} do
      other = topic_fixture(poet, %{label: "Embodied minds"})

      queued =
        excursion_fixture(poet, other, nil, %{requested_venue: "Machine Consciousness 0001"})

      plan = Poets.travel_plan(poet)
      assert plan.day == "excursion"
      assert plan.excursion.id == queued.id
      assert plan.excursion.topic_id == other.id
      assert plan.excursion.source == "chat"
      assert plan.excursion.requested_venue == "Machine Consciousness 0001"
      assert plan.reason =~ "asked for Machine Consciousness 0001"
      refute plan.excursion.topic_id == topic.id
    end

    test "once today's entry is linked, a retry makes the same decision", %{
      poet: poet,
      topic: topic
    } do
      entry = entry_fixture(poet)
      linked = excursion_fixture(poet, topic, entry)

      plan = Poets.travel_plan(poet)
      assert plan.day == "excursion"
      assert plan.excursion.id == linked.id
    end

    test "a retry after the poet already moved today stays a move day, with no excursion",
         %{poet: poet, topic: topic} do
      # the first attempt moved the poet, then did not publish
      {:ok, moved} =
        Poets.move_to(poet, %{
          lat: 36.53,
          lng: -6.29,
          place_name: "Cadiz, Spain",
          country_code: "ES"
        })

      plan = Poets.travel_plan(moved)
      assert plan.day == "move"
      assert plan.travel_today == false
      assert plan.excursion == nil
      assert plan.reason =~ "day 1 of 3"

      # a chat request waits too
      excursion_fixture(moved, topic, nil, %{requested_venue: "Oshkosh"})
      assert %{day: "move", excursion: nil} = Poets.travel_plan(moved)

      # the next day the topic is still due and the excursion happens
      tomorrow = Date.add(Date.utc_today(), 1)
      assert %{day: "excursion"} = Poets.travel_plan(moved, tomorrow)
    end

    test "with no topics the plan is exactly what it was", %{poet: poet, topic: topic} do
      {:ok, _} = TravelingPoet.Topics.delete(topic)

      assert %{day: "stay", travel_today: false, excursion: nil, reason: reason} =
               Poets.travel_plan(poet)

      assert reason =~ "day 2 of 3"
    end
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
