defmodule TravelingPoetWeb.CalendarWebTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, GoogleAuth, GoogleCalendar, GoogleDrive, Poets, Trips}
  alias TravelingPoetWeb.AuthController

  @drive GoogleAuth.scope(:drive)
  @calendar GoogleAuth.scope(:calendar)

  setup do
    Application.put_env(:traveling_poet, :sprites_client, TravelingPoet.SpritesClientRecorder)
    on_exit(fn -> Application.delete_env(:traveling_poet, :sprites_client) end)

    user =
      agent_user_fixture(%{
        onboarding_completed: true,
        google_id: "google-udi",
        home_place_name: "Lisbon, Portugal",
        home_lat: 38.7223,
        home_lng: -9.1393
      })

    poet = poet_fixture(user, %{name: "Wren"})
    published_entry_fixture(poet)

    Req.Test.stub(TravelingPoet.Google, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/calendar/v3/calendars/primary/events"} -> Req.Test.json(conn, %{"items" => []})
        {"POST", "/revoke"} -> Plug.Conn.send_resp(conn, 200, "")
      end
    end)

    %{user: user, poet: poet}
  end

  defp signed_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  defp google_auth(uid, scopes) do
    %Ueberauth.Auth{
      provider: :google,
      uid: uid,
      info: %Ueberauth.Auth.Info{email: "udi@example.com", name: "Udi"},
      credentials: %Ueberauth.Auth.Credentials{
        token: "access-1",
        refresh_token: "refresh-1",
        expires_at: System.os_time(:second) + 3600,
        scopes: scopes
      }
    }
  end

  defp callback(session, auth) do
    build_conn()
    |> Plug.Test.init_test_session(session)
    |> Phoenix.ConnTest.fetch_flash()
    |> Plug.Conn.assign(:ueberauth_auth, auth)
    |> AuthController.callback(%{})
  end

  defp intent(user), do: %{"feature" => "calendar", "user_id" => user.id}

  test "connect parks the intent and asks for the calendar alongside what is already held",
       %{conn: conn, user: user} do
    {:ok, user} =
      GoogleDrive.store_credentials(user, google_auth("google-udi", [@drive]).credentials)

    conn = conn |> signed_in(user) |> get(~p"/settings/calendar/connect")
    location = redirected_to(conn)
    assert location =~ "/auth/google?"
    query = location |> URI.parse() |> Map.get(:query) |> URI.decode_query()
    assert query["scope"] =~ @calendar
    assert query["scope"] =~ @drive
    assert query["access_type"] == "offline"
    assert get_session(conn, :google_connect) == intent(user)
  end

  test "connect is refused while calendars are admins-only", %{conn: conn, user: user} do
    Application.put_env(:traveling_poet, :calendar_enabled, "admins")
    on_exit(fn -> Application.put_env(:traveling_poet, :calendar_enabled, "all") end)

    conn = conn |> signed_in(user) |> get(~p"/settings/calendar/connect")
    assert redirected_to(conn) == "/settings#trips"
    assert get_session(conn, :google_connect) == nil
  end

  test "back from Google with the calendar allowed: grant kept, first sync run", %{user: user} do
    conn =
      callback(
        %{user_id: user.id, google_connect: intent(user)},
        google_auth("google-udi", ["email", @calendar])
      )

    assert redirected_to(conn) == "/settings#trips"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Looking for trips"
    user = Accounts.get_user!(user.id)
    assert GoogleCalendar.connected?(user)
    assert user.calendar_connected_at
    # the sync ran inline (test config) against the stubbed, empty calendar
    assert user.calendar_synced_at
  end

  test "a different Google account, or the calendar unticked, keeps nothing", %{user: user} do
    conn =
      callback(
        %{user_id: user.id, google_connect: intent(user)},
        google_auth("google-someone-else", ["email", @calendar])
      )

    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Google account you sign in with"
    refute GoogleCalendar.connected?(Accounts.get_user!(user.id))

    conn =
      callback(
        %{user_id: user.id, google_connect: intent(user)},
        google_auth("google-udi", ["email"])
      )

    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not allowed"
    refute GoogleCalendar.connected?(Accounts.get_user!(user.id))
  end

  test "the Trips card is hidden from non-admins while admins-only", %{conn: conn, user: user} do
    Application.put_env(:traveling_poet, :calendar_enabled, "admins")
    on_exit(fn -> Application.put_env(:traveling_poet, :calendar_enabled, "all") end)

    {:ok, _view, html} = live(signed_in(conn, user), ~p"/settings")
    refute html =~ ~s(id="trip-settings")
  end

  test "Settings: connect link with a home, then the connected state, then disconnect",
       %{conn: conn, user: user} do
    {:ok, _view, html} = live(signed_in(conn, user), ~p"/settings")
    assert html =~ ~s(id="trip-settings")
    assert html =~ "Lisbon, Portugal"
    assert html =~ ~s(id="connect-calendar")

    {:ok, user} =
      GoogleAuth.store_credentials(
        user,
        google_auth("google-udi", [@calendar]).credentials,
        :calendar
      )

    {:ok, view, html} = live(signed_in(build_conn(), user), ~p"/settings")
    assert html =~ ~s(id="calendar-status")
    assert html =~ ~s(id="sync-calendar")
    refute html =~ ~s(id="connect-calendar")

    html = view |> element("#sync-calendar") |> render_click()
    assert html =~ "Checking your calendar"
    assert Accounts.get_user!(user.id).calendar_synced_at

    html = view |> element("#sync-calendar") |> render_click()
    assert html =~ "checked a few minutes ago"

    html = view |> element("#disconnect-calendar") |> render_click()
    assert html =~ "Google Calendar disconnected"
    refute GoogleCalendar.connected?(Accounts.get_user!(user.id))
    assert html =~ ~s(id="connect-calendar")
  end

  test "Settings: a suggested trip can be scouted, which puts it on the itinerary, or dismissed",
       %{conn: conn, user: user, poet: poet} do
    trip = trip_fixture(poet)
    other = trip_fixture(poet, %{name: "Florence", event_ids: ["f"]})

    {:ok, view, html} = live(signed_in(conn, user), ~p"/settings")
    assert html =~ ~s(id="trip-suggested")
    assert html =~ "Rome"

    html = view |> element("#trip-accept-#{trip.id}") |> render_click()
    assert html =~ "Wren will scout Rome"
    assert html =~ "setting out on"
    assert html =~ ~s(id="trip-planned")
    assert html =~ ~s(id="trip-timing-#{trip.id}")
    assert html =~ "scouting from"
    assert html =~ "for your trip"
    assert [%{source: "trip", place_name: "Rome, Italy"}] = Poets.list_stops(poet.id)

    html = view |> element("#trip-dismiss-#{other.id}") |> render_click()
    refute html =~ ~s(id="trip-suggested")
    assert Trips.get(poet.id, other.id).status == "dismissed"

    html = view |> element("#trip-cancel-#{trip.id}") |> render_click()
    assert html =~ "called off"
    assert Poets.list_stops(poet.id) == []
  end

  test "Settings: a planned trip gone from the calendar can be kept", %{
    conn: conn,
    user: user,
    poet: poet
  } do
    trip = trip_fixture(poet)
    {:ok, _} = Trips.accept(poet, trip)
    Trips.reconcile(poet, [], "Lisbon")

    {:ok, view, html} = live(signed_in(conn, user), ~p"/settings")
    assert html =~ ~s(id="trip-gone-#{trip.id}")
    assert html =~ "No longer on your calendar"

    html = view |> element("#trip-keep-#{trip.id}") |> render_click()
    refute html =~ ~s(id="trip-gone-#{trip.id}")
    assert html =~ "Kept."
    assert Trips.get(poet.id, trip.id).calendar_gone_at == nil
  end

  test "the journal nudges about the nearest trip until it is answered", %{
    conn: conn,
    user: user,
    poet: poet
  } do
    trip = trip_fixture(poet)
    {:ok, view, html} = live(signed_in(conn, user), ~p"/journal")
    assert html =~ ~s(id="trip-nudge")
    assert html =~ "a trip to Rome"

    html = view |> element("#trip-nudge-accept-#{trip.id}") |> render_click()
    refute html =~ ~s(id="trip-nudge")
    assert Trips.get(poet.id, trip.id).status == "planned"
  end

  test "a sync elsewhere refreshes the open page", %{conn: conn, user: user, poet: poet} do
    {:ok, view, html} = live(signed_in(conn, user), ~p"/settings")
    refute html =~ ~s(id="trip-suggested")

    trip_fixture(poet)
    Phoenix.PubSub.broadcast(TravelingPoet.PubSub, "user:#{user.id}", {:trips_updated})
    assert render(view) =~ ~s(id="trip-suggested")
  end
end
