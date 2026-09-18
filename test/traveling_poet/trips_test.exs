defmodule TravelingPoet.TripsTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Poets, Trips, WebPush}
  alias TravelingPoet.ChangeStream.Serializer
  alias TravelingPoet.Telegram.Notifier
  alias TravelingPoet.Trips.Trip

  @today Date.utc_today()

  setup do
    user = user_fixture()
    poet = poet_fixture(user)
    Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "trips")
    Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "user:#{user.id}")
    %{user: user, poet: poet}
  end

  defp found(attrs \\ %{}) do
    start = Date.add(@today, 21)

    Map.merge(
      %{
        name: "Rome",
        start_date: start,
        end_date: Date.add(start, 3),
        destinations: [
          %{
            place_name: "Rome, Italy",
            lat: 41.9028,
            lng: 12.4964,
            country_code: "IT",
            arrive_on: start,
            depart_on: Date.add(start, 3)
          }
        ],
        event_ids: ["evt-rome"],
        signals: [
          %{
            id: "evt-rome",
            ical_uid: nil,
            kind: "stay",
            start: Date.to_iso8601(start),
            end: Date.to_iso8601(Date.add(start, 3)),
            location: "Rome, Italy"
          }
        ]
      },
      attrs
    )
  end

  describe "reconcile/4" do
    test "a new trip becomes a suggestion and is announced", %{user: user, poet: poet} do
      assert %{new: [trip], updated: 0, withdrawn: 0} =
               Trips.reconcile(poet, [found()], "Lisbon, Portugal")

      assert trip.status == "suggested"
      assert trip.source == "calendar"
      assert trip.name == "Rome"
      assert trip.home_place_name == "Lisbon, Portugal"
      assert [%{"place_name" => "Rome, Italy", "arrive_on" => _}] = Trip.destinations(trip)
      assert trip.event_ids == ["evt-rome"]
      assert %{"events" => [%{"kind" => "stay", "location" => "Rome, Italy"}]} = trip.signals
      assert_receive {:trip_suggested, user_id, trip_id}
      assert user_id == user.id and trip_id == trip.id
      assert_receive {:trips_updated}
    end

    test "the same events again change nothing", %{poet: poet} do
      Trips.reconcile(poet, [found()], "Lisbon")
      assert_receive {:trip_suggested, _, _}

      assert %{new: [], updated: 1, withdrawn: 0} = Trips.reconcile(poet, [found()], "Lisbon")
      assert [%{changed_at: nil}] = Trips.list(poet.id)
      refute_receive {:trip_suggested, _, _}
    end

    test "a moved event updates the suggestion and marks it changed", %{poet: poet} do
      Trips.reconcile(poet, [found()], "Lisbon")
      moved = found(%{start_date: Date.add(@today, 28), end_date: Date.add(@today, 31)})

      assert %{new: [], updated: 1} = Trips.reconcile(poet, [moved], "Lisbon")
      assert [trip] = Trips.list(poet.id)
      assert trip.start_date == Date.add(@today, 28)
      assert trip.changed_at
    end

    test "the same trip under new event ids is still the same trip", %{poet: poet} do
      Trips.reconcile(poet, [found()], "Lisbon")
      again = found(%{event_ids: ["evt-rome-2"]})
      assert %{new: [], updated: 1} = Trips.reconcile(poet, [again], "Lisbon")
      assert [%{event_ids: ["evt-rome-2"]}] = Trips.list(poet.id)
    end

    test "a dismissed trip stays dismissed and keeps matching", %{poet: poet} do
      %{new: [trip]} = Trips.reconcile(poet, [found()], "Lisbon")
      assert_receive {:trip_suggested, _, _}
      {:ok, _} = Trips.dismiss(trip)

      assert %{new: [], updated: 1} =
               Trips.reconcile(poet, [found(%{event_ids: ["evt-rome", "evt-hotel"]})], "Lisbon")

      assert [%{status: "dismissed", event_ids: ["evt-rome", "evt-hotel"]}] = Trips.list(poet.id)
      refute_receive {:trip_suggested, _, _}
    end

    test "a suggestion whose events left the calendar is withdrawn; a planned trip is not",
         %{poet: poet} do
      %{new: [rome]} = Trips.reconcile(poet, [found()], "Lisbon")
      assert_receive {:trip_suggested, _, _}

      florence =
        found(%{
          name: "Florence",
          event_ids: ["evt-florence"],
          destinations: [
            %{
              hd(found().destinations)
              | place_name: "Florence, Italy",
                lat: 43.7696,
                lng: 11.2558
            }
          ]
        })

      %{new: [flo]} = Trips.reconcile(poet, [found(), florence], "Lisbon")
      {:ok, _} = Trips.accept(poet, flo)

      assert %{new: [], updated: 0, withdrawn: 1} = Trips.reconcile(poet, [], "Lisbon")
      assert [%{id: id, status: "planned"}] = Trips.list(poet.id)
      assert id == flo.id
      assert Trips.get(poet.id, rome.id) == nil
    end

    test "a dismissed trip is offered again only when it changed materially", %{poet: poet} do
      %{new: [trip]} = Trips.reconcile(poet, [found()], "Lisbon")
      assert_receive {:trip_suggested, _, _}
      {:ok, _} = Trips.dismiss(trip)

      # a few days later, or a different end: still the trip they declined
      nudged = found(%{start_date: Date.add(@today, 25), end_date: Date.add(@today, 30)})
      assert %{new: [], updated: 1} = Trips.reconcile(poet, [nudged], "Lisbon")
      assert [%{status: "dismissed"}] = Trips.list(poet.id)
      refute_receive {:trip_suggested, _, _}

      # moved by more than a week: a trip they have not seen
      moved = found(%{start_date: Date.add(@today, 35), end_date: Date.add(@today, 38)})
      assert %{new: [again], updated: 0} = Trips.reconcile(poet, [moved], "Lisbon")
      assert again.id == trip.id
      assert again.status == "suggested"
      assert again.changed_at
      assert again.start_date == Date.add(@today, 35)
      assert_receive {:trip_suggested, _, id}
      assert id == trip.id
    end

    test "a planned trip that left the calendar is marked, kept or called off, never dropped",
         %{poet: poet} do
      %{new: [trip]} = Trips.reconcile(poet, [found()], "Lisbon")
      assert_receive {:trip_suggested, _, _}
      {:ok, trip} = Trips.accept(poet, trip)

      assert %{withdrawn: 0} = Trips.reconcile(poet, [], "Lisbon")
      gone = Trips.get(poet.id, trip.id)
      assert gone.status == "planned"
      assert gone.calendar_gone_at

      # back on the calendar: the mark clears
      assert %{updated: 1} = Trips.reconcile(poet, [found()], "Lisbon")
      assert Trips.get(poet.id, trip.id).calendar_gone_at == nil

      # gone again, and kept by hand: it is theirs now, whatever the calendar says
      Trips.reconcile(poet, [], "Lisbon")
      {:ok, kept} = Trips.keep(poet, Trips.get(poet.id, trip.id))
      assert kept.calendar_gone_at == nil
      assert kept.source == "settings"
      assert [stop] = Trips.stops(trip.id)
      assert stop.source == "trip"
    end

    test "a planned trip that moves on the calendar is announced", %{poet: poet} do
      %{new: [trip]} = Trips.reconcile(poet, [found()], "Lisbon")
      assert_receive {:trip_suggested, _, _}
      {:ok, _} = Trips.accept(poet, trip)

      moved = found(%{start_date: Date.add(@today, 30), end_date: Date.add(@today, 33)})
      assert %{changed: [changed], updated: 1} = Trips.reconcile(poet, [moved], "Lisbon")
      assert changed.id == trip.id
      assert changed.scout_from == Date.add(@today, 26)
      assert_receive {:trip_changed, _, id}
      assert id == trip.id

      text = Notifier.trip_changed_text(poet, changed, "https://poet.travel/settings#trips")
      assert text =~ "is now"
      assert text =~ "will set out on"
      payload = WebPush.trip_changed_payload(poet, changed)
      assert payload.title =~ "moved"

      # the same dates again: nothing to say
      assert %{changed: []} = Trips.reconcile(poet, [moved], "Lisbon")
      refute_receive {:trip_changed, _, _}
    end

    test "a suggestion for a trip already under way is withdrawn", %{poet: poet} do
      stale = found(%{start_date: Date.add(@today, -1), end_date: Date.add(@today, 2)})
      %{new: [_]} = Trips.reconcile(poet, [stale], "Lisbon")
      assert %{withdrawn: 1} = Trips.reconcile(poet, [stale], "Lisbon")
      assert Trips.list(poet.id) == []
    end
  end

  describe "accept/2 and cancel/2" do
    test "accepting plans the trip and puts its destinations on the itinerary", %{poet: poet} do
      trip = trip_fixture(poet)
      assert {:ok, %{status: "planned", decided_at: %DateTime{}}} = Trips.accept(poet, trip)

      assert [stop] = Poets.list_stops(poet.id)
      assert stop.source == "trip"
      assert stop.trip_id == trip.id
      assert stop.place_name == "Rome, Italy"

      # again: no second stop
      assert {:ok, _} = Trips.accept(poet, Trips.get(poet.id, trip.id))
      assert length(Poets.list_stops(poet.id)) == 1
    end

    test "calling a trip off drops its unvisited stops and dismisses it", %{poet: poet} do
      trip = trip_fixture(poet)
      other = stop_fixture(poet)
      {:ok, trip} = Trips.accept(poet, trip)

      assert {:ok, %{status: "dismissed"}} = Trips.cancel(poet, trip)
      assert [%{id: id}] = Poets.list_stops(poet.id)
      assert id == other.id
    end

    test "disconnecting withdraws open suggestions only", %{poet: poet} do
      _open = trip_fixture(poet)
      planned = trip_fixture(poet, %{event_ids: ["p"]})
      {:ok, _} = Trips.accept(poet, planned)

      assert Trips.withdraw_suggestions(poet.id) == 1
      assert [%{status: "planned"}] = Trips.list(poet.id)
    end
  end

  test "date ranges read like a person wrote them" do
    assert Trips.date_range(~D[2026-10-03], ~D[2026-10-09]) == "3 to 9 October"
    assert Trips.date_range(~D[2026-09-28], ~D[2026-10-03]) == "28 September to 3 October"
    assert Trips.date_range(~D[2026-12-30], ~D[2027-01-02]) == "30 December to 2 January 2027"
    assert Trips.date_range(~D[2026-10-03], ~D[2026-10-03]) == "3 October"
  end

  test "the notes about a found trip say where and when, without emoji", %{poet: poet} do
    trip = trip_fixture(poet)
    text = Notifier.trip_suggested_text(poet, trip, "https://poet.travel/settings#trips")
    assert text =~ "a trip to Rome"
    assert text =~ poet.name
    assert text =~ "https://poet.travel/settings#trips"
    refute text =~ ~r/[\x{1F300}-\x{1FAFF}\x{2600}-\x{27BF}]/u

    payload = WebPush.trip_suggested_payload(poet, trip)
    assert payload.title =~ "Rome"
    assert payload.url == "/settings#trips"
    assert payload.tag == "trip-#{trip.id}"
  end

  test "the calendar events behind a trip never leave the app; the trip itself does" do
    assert Serializer.redacted_field?("trips", "signals")
    refute Serializer.redacted_field?("trips", "destinations")
    refute Serializer.redacted_field?("trips", "name")
  end
end
