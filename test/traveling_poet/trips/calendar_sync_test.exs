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

  defmodule FakeSession do
    def run(user, note, _opts) do
      if pid = Process.whereis(:calendar_sync_away_test),
        do: send(pid, {:session_run, user.id, note})

      {:ok, "Looking."}
    end
  end

  test "a trip under way puts the companion there, and Near you looks around it the same day" do
    Process.register(self(), :calendar_sync_away_test)
    Application.put_env(:traveling_poet, :agent_session, FakeSession)
    Application.put_env(:traveling_poet, :near_home_enabled, true)

    on_exit(fn ->
      Application.delete_env(:traveling_poet, :agent_session)
      Application.delete_env(:traveling_poet, :near_home_enabled)
    end)

    user = calendar_user_fixture(%{credits: 10, onboarding_completed: true})
    poet_fixture(user)

    remember("Rome, Italy", %{
      lat: 41.9028,
      lng: 12.4964,
      country_code: "IT",
      city: "Rome",
      country: "Italy"
    })

    # landed yesterday: too late to suggest, but they are there
    calendar([rome_event(-1)])

    assert {:ok, %{new: []}} = CalendarSync.sync_user(user)
    user = Accounts.get_user!(user.id)
    assert user.trip_here_name == "Rome, Italy"
    # an all-day event ends the day before its exclusive end date
    assert user.trip_here_until == Date.add(Date.utc_today(), 2)
    assert_receive {:session_run, _, note}, 2000
    assert note =~ "A trip on their calendar puts them in Rome, Italy"

    # home again: the next sync forgets it
    calendar([])
    assert {:ok, _} = CalendarSync.sync_user(user)
    assert Accounts.get_user!(user.id).trip_here_name == nil
  end
end
