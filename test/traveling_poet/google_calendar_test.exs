defmodule TravelingPoet.GoogleCalendarTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, GoogleCalendar}

  @stub TravelingPoet.Google

  defp events(test_pid, pages) do
    Req.Test.stub(@stub, fn conn ->
      send(
        test_pid,
        {:google, conn.method, conn.request_path, URI.decode_query(conn.query_string)}
      )

      case {conn.method, conn.request_path} do
        {"GET", "/calendar/v3/calendars/primary/events"} ->
          token = URI.decode_query(conn.query_string)["pageToken"]
          Req.Test.json(conn, Map.fetch!(pages, token))

        {"POST", "/token"} ->
          Req.Test.json(conn, %{"access_token" => "access-2", "expires_in" => 3599})
      end
    end)
  end

  test "lists the primary calendar's events for the window, following pages" do
    user = calendar_user_fixture()

    events(self(), %{
      nil => %{
        "items" => [
          %{
            "id" => "a",
            "iCalUID" => "a@google.com",
            "status" => "confirmed",
            "summary" => "Workshop",
            "location" => "Rome, Italy",
            "start" => %{"date" => "2026-10-20"},
            "end" => %{"date" => "2026-10-24"}
          }
        ],
        "nextPageToken" => "p2"
      },
      "p2" => %{
        "items" => [
          %{
            "id" => "b",
            "status" => "confirmed",
            "eventType" => "fromGmail",
            "location" => "Fiumicino Airport (FCO)",
            "start" => %{"dateTime" => "2026-10-20T06:30:00+01:00", "timeZone" => "Europe/Lisbon"},
            "end" => %{"dateTime" => "2026-10-20T09:45:00+02:00", "timeZone" => "Europe/Rome"}
          },
          %{"id" => "c", "status" => "cancelled"}
        ]
      }
    })

    assert {:ok, [a, b], %Accounts.User{}} =
             GoogleCalendar.list_events(user, ~D[2026-10-01], ~D[2027-01-29])

    assert_receive {:google, "GET", "/calendar/v3/calendars/primary/events", query}
    assert query["timeMin"] == "2026-10-01T00:00:00Z"
    assert query["timeMax"] == "2027-01-29T00:00:00Z"
    assert query["singleEvents"] == "true"
    assert query["orderBy"] == "startTime"
    assert_receive {:google, "GET", _, %{"pageToken" => "p2"}}

    assert a.id == "a"
    assert a.event_type == "default"
    assert a.all_day?
    assert a.start_on == ~D[2026-10-20]
    # Google's all-day end is exclusive
    assert a.end_on == ~D[2026-10-23]

    assert b.event_type == "fromGmail"
    refute b.all_day?
    assert b.start_on == ~D[2026-10-20]
    assert b.end_on == ~D[2026-10-20]
    assert b.location == "Fiumicino Airport (FCO)"
  end

  test "an expired access token is refreshed first" do
    user = calendar_user_fixture()

    {:ok, user} =
      Accounts.update_user(user, %{
        google_token_expires_at:
          DateTime.add(DateTime.utc_now(), -10) |> DateTime.truncate(:second)
      })

    events(self(), %{nil => %{"items" => []}})
    assert {:ok, [], user} = GoogleCalendar.list_events(user, ~D[2026-10-01], ~D[2026-10-02])
    assert_receive {:google, "POST", "/token", _}
    assert user.google_access_token == "access-2"
  end

  test "Google refusing the token asks to reconnect; refusing the calendar is forbidden" do
    user = calendar_user_fixture()
    Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 401, "") end)
    assert {:error, :reconnect} = GoogleCalendar.list_events(user, ~D[2026-10-01], ~D[2026-10-02])

    Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 403, "") end)
    assert {:error, :forbidden} = GoogleCalendar.list_events(user, ~D[2026-10-01], ~D[2026-10-02])
  end

  test "normalize_event/1 keeps the end no earlier than the start and drops the unusable" do
    assert %{start_on: ~D[2026-10-20], end_on: ~D[2026-10-20]} =
             GoogleCalendar.normalize_event(%{
               "id" => "x",
               "start" => %{"date" => "2026-10-20"},
               "end" => %{"date" => "2026-10-20"}
             })

    assert nil == GoogleCalendar.normalize_event(%{"id" => "y", "start" => %{}, "end" => %{}})
    assert nil == GoogleCalendar.normalize_event(%{"id" => "z", "status" => "cancelled"})
  end
end
