defmodule TravelingPoet.Trips.TravelPlanTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Credits, DailyJourneyScheduler, Poets, Trips}

  @today Date.utc_today()

  # A poet at Lisbon since `days_ago`, with the given mission.
  defp poet_at_lisbon(user, days_ago, attrs \\ %{}) do
    arrived = DateTime.add(DateTime.utc_now(), -days_ago, :day) |> DateTime.truncate(:second)
    poet_fixture(user, Map.merge(%{arrived_at: arrived}, attrs))
  end

  # A trip to Rome then Florence, accepted, starting `starts_in` days from now.
  defp planned_trip(poet, starts_in) do
    start = Date.add(@today, starts_in)

    trip =
      trip_fixture(poet, %{
        name: "Rome and Florence",
        start_date: start,
        end_date: Date.add(start, 6),
        destinations: %{
          "items" => [
            %{
              "place_name" => "Rome, Italy",
              "lat" => 41.9028,
              "lng" => 12.4964,
              "country_code" => "IT"
            },
            %{
              "place_name" => "Florence, Italy",
              "lat" => 43.7696,
              "lng" => 11.2558,
              "country_code" => "IT"
            }
          ]
        }
      })

    {:ok, trip} = Trips.accept(poet, trip)
    trip
  end

  # From the stored poet: a struct with an arrived_at in the same second as
  # "now" would leave the timestamp unchanged.
  defp arrive(poet, stop) do
    {:ok, poet} =
      poet.id
      |> Poets.get_poet()
      |> Poets.move_to(%{lat: stop.lat, lng: stop.lng, place_name: stop.place_name})

    {:ok, _} = Poets.mark_stop_visited(poet.id, stop.id)
    Poets.get_poet(poet.id)
  end

  defp days_ago(poet, n) do
    {:ok, poet} =
      Poets.update_poet(poet, %{arrived_at: DateTime.add(DateTime.utc_now(), -n, :day)})

    poet
  end

  test "accepting sets the day the poet sets out: a stay per stop, plus one" do
    user = user_fixture()
    poet = poet_at_lisbon(user, 5)
    trip = planned_trip(poet, 30)

    # two stops x 3 days + 1
    assert trip.scout_from == Date.add(@today, 23)
    assert trip.status == "planned"

    soon = planned_trip(poet, 4)
    assert soon.status == "scouting"
    assert Date.compare(soon.scout_from, @today) != :gt
  end

  test "a wanderer keeps wandering until the trip's day, then scouts it, then wanders again" do
    user = user_fixture()
    poet = poet_at_lisbon(user, 5)
    trip = planned_trip(poet, 30)

    # before scout_from: the wander plan, and the trip's stops are not a route
    plan = Poets.travel_plan(poet)
    assert plan.travel_today
    assert plan.destination == nil
    refute plan.scouting
    assert plan.trip == nil
    assert Poets.route_stops(poet) == []
    refute Poets.scouting?(poet)

    # the day comes: set out at once, whatever the stay count says
    fresh = days_ago(poet, 0)
    on_day = trip.scout_from
    plan = Poets.travel_plan(fresh, on_day)
    assert plan.travel_today
    assert plan.scouting
    assert plan.trip.name == "Rome and Florence"
    assert plan.destination.place_name == "Rome, Italy"
    assert plan.destination.source == "trip"
    assert plan.reason =~ "set out now"
    assert Poets.scouting?(fresh, on_day)
    assert length(Poets.route_stops(fresh, on_day)) == 2

    # in Rome: an ordinary stay, then on to Florence
    [rome, florence] = Trips.stops(trip.id)
    in_rome = arrive(fresh, rome)
    plan = Poets.travel_plan(in_rome, on_day)
    refute plan.travel_today
    assert plan.reason =~ "day 1 of 3"
    assert plan.scouting

    plan = in_rome |> days_ago(3) |> Poets.travel_plan(on_day)
    assert plan.travel_today
    assert plan.destination.place_name == "Florence, Italy"
    assert plan.reason =~ "trip's next stop"

    # in Florence, stay done: the trip is scouted, finish the stay
    in_florence = in_rome |> arrive(florence)
    plan = Poets.travel_plan(in_florence, on_day)
    refute plan.travel_today
    assert plan.reason =~ "day 1 of 3"

    plan = in_florence |> days_ago(3) |> Poets.travel_plan(on_day)
    assert plan.scouting
    assert plan.reason =~ "trip to Rome and Florence is scouted"
    refute plan.travel_today

    # the scheduler closes it before the next run, and the wanderer is free
    done = days_ago(in_florence, 3)
    assert Trips.activate(done, on_day) == nil
    assert Trips.get(poet.id, trip.id).status == "done"
    plan = Poets.travel_plan(done, on_day)
    refute plan.scouting
    assert plan.travel_today
    assert plan.destination == nil
    assert plan.reason =~ "NOT in `visited`"
  end

  test "a scout keeps its own itinerary; the trip's stops wait for their day and go first then" do
    user = user_fixture()
    poet = poet_at_lisbon(user, 5, %{settings: %{"mode" => "scout"}})
    porto = stop_fixture(poet)
    trip = planned_trip(poet, 30)

    plan = Poets.travel_plan(poet)
    assert plan.destination.id == porto.id
    assert Enum.map(Poets.route_stops(poet), & &1.id) == [porto.id]
    assert Poets.next_stop_to_travel(poet).id == porto.id

    on_day = trip.scout_from
    plan = Poets.travel_plan(poet, on_day)
    assert plan.destination.place_name == "Rome, Italy"
    assert plan.trip.id == trip.id
    assert Enum.map(Poets.route_stops(poet, on_day), & &1.trip_id) == [trip.id, trip.id]
  end

  test "a hold and a chat detour still come first on a trip day" do
    user = user_fixture()
    poet = poet_at_lisbon(user, 5)
    trip = planned_trip(poet, 30)
    on_day = trip.scout_from

    {:ok, held} = Poets.hold(poet, 2, on_day)
    assert %{travel_today: false, reason: reason} = Poets.travel_plan(held, on_day)
    assert reason =~ "asked you to stay"

    {:ok, _} = Poets.insert_stop_next(poet.id, %{place_name: "Aveiro", lat: 40.64, lng: -8.65})
    plan = Poets.travel_plan(poet, on_day)
    assert plan.travel_today
    assert plan.destination.place_name == "Aveiro"
  end

  test "the scheduler starts a planned trip on its day and prices the run as a scout's" do
    user = user_fixture(%{credits: 3})
    poet = poet_at_lisbon(user, 5)
    assert DailyJourneyScheduler.eligible(user, poet) == :ok

    trip = planned_trip(poet, 4)
    assert trip.status == "scouting"
    assert Credits.daily_run_cost(poet, scouting: true) == 5000
    assert DailyJourneyScheduler.eligible(user, poet) == {:skip, "out of credits"}

    user = user_fixture(%{credits: 10})
    poet = poet_at_lisbon(user, 5)
    trip = planned_trip(poet, 30)

    {:ok, _} =
      TravelingPoet.Repo.update(
        Ecto.Changeset.change(Trips.get(poet.id, trip.id), scout_from: @today)
      )

    assert Trips.get(poet.id, trip.id).status == "planned"
    assert %{status: "scouting"} = Trips.activate(poet)

    {:ok, debit} = Credits.debit_daily_run(user, poet, 1, day: "move", scouting: true)
    assert debit.amount == -5000
    assert debit.metadata["mode"] == "scout"
    assert debit.metadata["mission"] == "wander"
  end

  test "moving the trip on the calendar moves the day the poet sets out" do
    user = user_fixture()
    poet = poet_at_lisbon(user, 5)
    trip = planned_trip(poet, 30)

    found = %{
      name: "Rome and Florence",
      start_date: Date.add(@today, 40),
      end_date: Date.add(@today, 46),
      destinations: [
        %{
          place_name: "Rome, Italy",
          lat: 41.9028,
          lng: 12.4964,
          country_code: "IT",
          arrive_on: Date.add(@today, 40),
          depart_on: Date.add(@today, 43)
        }
      ],
      event_ids: trip.event_ids,
      signals: []
    }

    assert %{updated: 1} = Trips.reconcile(poet, [found], "Lisbon")
    moved = Trips.get(poet.id, trip.id)
    assert moved.status == "planned"
    assert moved.start_date == Date.add(@today, 40)
    assert moved.scout_from == Date.add(@today, 33)
    assert moved.changed_at
    assert length(Trips.stops(trip.id)) == 2
  end

  test "removing a trip's stop reschedules it; removing the last one calls it off" do
    user = user_fixture()
    poet = poet_at_lisbon(user, 5)
    trip = planned_trip(poet, 30)
    [rome, florence] = Trips.stops(trip.id)

    {:ok, _} = Poets.remove_stop(poet.id, florence.id)
    Trips.after_stop_removed(poet, trip.id)
    assert Trips.get(poet.id, trip.id).scout_from == Date.add(@today, 26)

    {:ok, _} = Poets.remove_stop(poet.id, rome.id)
    Trips.after_stop_removed(poet, trip.id)
    assert Trips.get(poet.id, trip.id).status == "dismissed"
  end
end
