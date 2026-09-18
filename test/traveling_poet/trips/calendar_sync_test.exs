defmodule TravelingPoet.Trips.CalendarSyncTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, GoogleAuth, Repo, Trips}
  alias TravelingPoet.Geocoder.CacheEntry
  alias TravelingPoet.Trips.CalendarSync

  @stub TravelingPoet.Google

  defp remember(query, attrs) do
    %CacheEntry{}
    |> CacheEntry.changeset(
      Map.merge(
        %{
          query_hash: CacheEntry.hash(query),
          query: query,
          found: true,
          looked_up_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp calendar(items) do
    Req.Test.stub(@stub, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/calendar/v3/calendars/primary/events"} ->
          Req.Test.json(conn, %{"items" => items})
      end
    end)
  end

  defp rome_event(offset) do
    %{
      "id" => "evt-rome",
      "status" => "confirmed",
      "summary" => "Workshop",
      "location" => "Rome, Italy",
      "start" => %{"date" => Date.to_iso8601(Date.add(Date.utc_today(), offset))},
      "end" => %{"date" => Date.to_iso8601(Date.add(Date.utc_today(), offset + 4))}
    }
  end

  test "reads the calendar, geocodes through the cache, and suggests the trip" do
    user = calendar_user_fixture()
    poet = poet_fixture(user)

    remember("Rome, Italy", %{
      lat: 41.9028,
      lng: 12.4964,
      country_code: "IT",
      city: "Rome",
      country: "Italy"
    })

    calendar([rome_event(21)])

    assert {:ok, %{new: [trip]}} = CalendarSync.sync_user(user)
    assert trip.name == "Rome"
    assert trip.poet_id == poet.id
    assert [%{"place_name" => "Rome, Italy"}] = TravelingPoet.Trips.Trip.destinations(trip)

    user = Accounts.get_user!(user.id)
    assert user.calendar_synced_at
    assert user.calendar_error == nil
  end

  test "a location the geocoder does not know is not a trip; nothing reaches Nominatim" do
    user = calendar_user_fixture()
    poet_fixture(user)
    calendar([rome_event(21)])

    assert {:ok, %{new: []}} = CalendarSync.sync_user(user)
  end

  test "Google refusing the token is recorded for the card" do
    user = calendar_user_fixture()
    poet = poet_fixture(user)
    Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 401, "") end)

    assert {:error, :reconnect} = CalendarSync.sync_user(user)
    assert Accounts.get_user!(user.id).calendar_error == "reconnect"
    assert Trips.list(poet.id) == []
  end

  test "a companion with no home, or no poet, is skipped quietly" do
    user = calendar_user_fixture(%{home_lat: nil, home_lng: nil})
    poet_fixture(user)
    assert {:error, :no_home} = CalendarSync.sync_user(user)
    assert Accounts.get_user!(user.id).calendar_error == nil

    assert {:error, :no_poet} = CalendarSync.sync_user(calendar_user_fixture())
  end

  test "a pass syncs every connected companion with a home, and only those" do
    user = calendar_user_fixture()
    poet_fixture(user)
    # a Drive-only user, and one without a home, are not calendar companions
    _drive_only =
      user_fixture(%{google_refresh_token: "r", google_scopes: [GoogleAuth.scope(:drive)]})

    _homeless = calendar_user_fixture(%{home_lat: nil, home_lng: nil})
    calendar([])

    assert [{id, {:ok, _}}] = CalendarSync.sync_all()
    assert id == user.id
  end
end
