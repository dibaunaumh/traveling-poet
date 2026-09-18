defmodule TravelingPoet.Trips.DetectorTest do
  use ExUnit.Case, async: true

  alias TravelingPoet.Trips.Detector

  @today ~D[2026-10-01]
  @home %{lat: 38.7223, lng: -9.1393}

  @rome %{lat: 41.9028, lng: 12.4964, country_code: "IT", city: "Rome", country: "Italy"}
  @florence %{lat: 43.7696, lng: 11.2558, country_code: "IT", city: "Florence", country: "Italy"}
  @venice %{lat: 45.4408, lng: 12.3155, country_code: "IT", city: "Venice", country: "Italy"}
  @fiumicino %{lat: 41.8003, lng: 12.2389, country_code: "IT", city: nil, country: "Italy"}
  @cascais %{lat: 38.6979, lng: -9.4215, country_code: "PT", city: "Cascais", country: "Portugal"}

  @resolved %{
    "Rome, Italy" => @rome,
    "Via Veneto 1, Rome" => @rome,
    "Florence, Italy" => @florence,
    "Venice, Italy" => @venice,
    "Fiumicino Airport (FCO)" => @fiumicino,
    "Cascais, Portugal" => @cascais,
    "Nowhere" => :not_found
  }

  defp ev(attrs) do
    Map.merge(
      %{
        id: "e#{System.unique_integer([:positive])}",
        ical_uid: nil,
        status: "confirmed",
        summary: "Something",
        location: nil,
        event_type: "default",
        all_day?: true,
        start_on: Date.add(@today, 20),
        end_on: Date.add(@today, 23)
      },
      attrs
    )
  end

  defp detect(events, opts \\ %{}), do: Detector.detect(events, @resolved, @home, @today, opts)

  test "a multi-day event far from home is a trip, named after its city" do
    event = ev(%{location: "Rome, Italy"})
    assert [trip] = detect([event])
    assert trip.name == "Rome"
    assert trip.start_date == Date.add(@today, 20)
    assert trip.end_date == Date.add(@today, 23)
    assert [dest] = trip.destinations
    assert dest.place_name == "Rome, Italy"
    assert dest.lat == @rome.lat
    assert dest.country_code == "IT"
    assert dest.arrive_on == trip.start_date
    assert trip.event_ids == [event.id]
    assert [%{kind: "stay", location: "Rome, Italy", start: _, end: _}] = trip.signals
    refute Map.has_key?(hd(trip.signals), :summary)
  end

  test "an ordinary event needs at least two calendar days" do
    day = Date.add(@today, 20)
    assert [] = detect([ev(%{location: "Rome, Italy", start_on: day, end_on: day})])
    assert [_] = detect([ev(%{location: "Rome, Italy", start_on: day, end_on: Date.add(day, 1)})])
  end

  test "a place near home, a place nobody can find, and no place at all are not travel" do
    assert [] = detect([ev(%{location: "Cascais, Portugal"})])
    assert [] = detect([ev(%{location: "Nowhere"})])
    assert [] = detect([ev(%{location: "Somewhere unresolved"})])
    assert [] = detect([ev(%{location: nil})])
    assert [] = detect([ev(%{location: "  "})])
  end

  test "cancelled, birthday and past events are ignored" do
    assert [] = detect([ev(%{location: "Rome, Italy", status: "cancelled"})])
    assert [] = detect([ev(%{location: "Rome, Italy", event_type: "birthday"})])

    assert [] =
             detect([
               ev(%{location: "Rome, Italy", start_on: ~D[2026-09-20], end_on: ~D[2026-09-25]})
             ])
  end

  test "two Gmail booking legs abutting in time are one trip with two destinations" do
    flight =
      ev(%{
        event_type: "fromGmail",
        location: "Fiumicino Airport (FCO)",
        all_day?: false,
        start_on: Date.add(@today, 20),
        end_on: Date.add(@today, 20)
      })

    hotel =
      ev(%{
        event_type: "fromGmail",
        location: "Florence, Italy",
        start_on: Date.add(@today, 21),
        end_on: Date.add(@today, 25)
      })

    assert [trip] = detect([hotel, flight])
    assert trip.name == "Fiumicino Airport (FCO) and Florence"

    assert Enum.map(trip.destinations, & &1.place_name) == [
             "Fiumicino Airport (FCO), Italy",
             "Florence, Italy"
           ]

    assert trip.start_date == Date.add(@today, 20)
    assert trip.end_date == Date.add(@today, 25)
    assert Enum.sort(trip.event_ids) == Enum.sort([flight.id, hotel.id])
  end

  test "a Gmail booking and an ordinary event in the same city are one trip, one destination" do
    stay =
      ev(%{location: "Rome, Italy", start_on: Date.add(@today, 20), end_on: Date.add(@today, 23)})

    hotel =
      ev(%{
        event_type: "fromGmail",
        location: "Via Veneto 1, Rome",
        start_on: Date.add(@today, 20),
        end_on: Date.add(@today, 23)
      })

    assert [trip] = detect([stay, hotel])
    assert [%{place_name: "Rome, Italy"}] = trip.destinations
    assert length(trip.event_ids) == 2
  end

  test "ordinary events in two different cities are two trips even back to back" do
    rome =
      ev(%{location: "Rome, Italy", start_on: Date.add(@today, 20), end_on: Date.add(@today, 22)})

    florence =
      ev(%{
        location: "Florence, Italy",
        start_on: Date.add(@today, 23),
        end_on: Date.add(@today, 25)
      })

    assert [%{name: "Rome"}, %{name: "Florence"}] = detect([florence, rome])
  end

  test "an out-of-office block widens the trip it overlaps and makes none on its own" do
    rome =
      ev(%{location: "Rome, Italy", start_on: Date.add(@today, 21), end_on: Date.add(@today, 23)})

    ooo =
      ev(%{
        event_type: "outOfOffice",
        start_on: Date.add(@today, 20),
        end_on: Date.add(@today, 24)
      })

    assert [trip] = detect([rome, ooo])
    assert trip.start_date == Date.add(@today, 20)
    assert trip.end_date == Date.add(@today, 24)
    assert ooo.id in trip.event_ids
    assert Enum.any?(trip.signals, &(&1.kind == "ooo"))
    assert [%{place_name: "Rome, Italy"}] = trip.destinations

    assert [] = detect([ooo])
  end

  test "a stretch too long to be a trip, and one starting too soon, are dropped" do
    long =
      ev(%{location: "Rome, Italy", start_on: Date.add(@today, 10), end_on: Date.add(@today, 70)})

    assert [] = detect([long])
    assert [_] = detect([long], %{max_trip_days: 90})

    soon =
      ev(%{location: "Rome, Italy", start_on: Date.add(@today, 1), end_on: Date.add(@today, 4)})

    assert [] = detect([soon])

    just_in_time =
      ev(%{location: "Rome, Italy", start_on: Date.add(@today, 2), end_on: Date.add(@today, 4)})

    assert [_] = detect([just_in_time])
  end

  test "three cities are named as two and more; trips come sorted by start" do
    later =
      ev(%{
        location: "Venice, Italy",
        start_on: Date.add(@today, 40),
        end_on: Date.add(@today, 42)
      })

    legs =
      for {loc, offset} <- [{"Rome, Italy", 20}, {"Florence, Italy", 22}, {"Venice, Italy", 24}] do
        ev(%{
          event_type: "fromGmail",
          location: loc,
          start_on: Date.add(@today, offset),
          end_on: Date.add(@today, offset + 1)
        })
      end

    assert [big, %{name: "Venice"}] = detect([later | legs])
    assert big.name == "Rome, Florence and 1 more"
  end

  test "a Gmail flight with no location is read from its title, and only then" do
    flight = ev(%{event_type: "fromGmail", summary: "Flight to Rome (FCO)", location: nil})
    assert Detector.location_of(flight) == "Rome"
    assert Detector.location_of(%{flight | summary: "Train to Florence"}) == "Florence"

    assert Detector.location_of(%{flight | location: "Fiumicino Airport (FCO)"}) ==
             "Fiumicino Airport (FCO)"

    assert Detector.location_of(%{flight | summary: "Dinner with Rome"}) == nil
    # an ordinary event's title is never read
    assert Detector.location_of(ev(%{summary: "Flight to Rome (FCO)", location: nil})) == nil

    assert Detector.locations([flight], @today) == ["Rome"]

    resolved = Map.put(@resolved, "Rome", @rome)

    assert [trip] =
             Detector.detect(
               [%{flight | start_on: Date.add(@today, 20), end_on: Date.add(@today, 20)}],
               resolved,
               @home,
               @today
             )

    assert trip.name == "Rome"
    assert [%{location: "Rome", kind: "gmail"}] = trip.signals
  end

  test "locations/2 lists each candidate's location once, before anything is geocoded" do
    events = [
      ev(%{location: "Rome, Italy"}),
      ev(%{location: "Rome, Italy"}),
      ev(%{location: "Cascais, Portugal"}),
      ev(%{location: "One day", start_on: Date.add(@today, 5), end_on: Date.add(@today, 5)}),
      ev(%{location: nil}),
      ev(%{event_type: "outOfOffice"}),
      ev(%{location: "Gone", start_on: ~D[2026-09-01], end_on: ~D[2026-09-03]})
    ]

    assert Detector.locations(events, @today) == ["Rome, Italy", "Cascais, Portugal"]
  end
end
