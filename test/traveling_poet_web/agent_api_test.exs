defmodule TravelingPoetWeb.AgentApiTest do
  use TravelingPoetWeb.ConnCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.Journal

  setup %{conn: conn} do
    user = agent_user_fixture()
    poet = poet_fixture(user)

    authed =
      conn
      |> put_req_header("authorization", "Bearer #{user.agent_api_token}")
      |> put_req_header("content-type", "application/json")

    %{conn: authed, anon: conn, user: user, poet: poet}
  end

  test "rejects missing/invalid bearer", %{anon: anon} do
    assert anon |> get(~p"/api/agent/context") |> json_response(401)

    assert anon
           |> put_req_header("authorization", "Bearer 1.not-the-token")
           |> get(~p"/api/agent/context")
           |> json_response(401)
  end

  test "GET /context returns poet profile and location", %{conn: conn, poet: poet} do
    body = conn |> get(~p"/api/agent/context") |> json_response(200)

    assert body["poet"]["name"] == poet.name
    assert body["location"]["place_name"] == "Lisbon, Portugal"
    assert body["today"]
  end

  test "entry upsert + sections + publish round-trip", %{conn: conn, poet: poet} do
    date = Date.utc_today() |> Date.to_iso8601()

    assert %{"ok" => true} =
             conn
             |> post(~p"/api/agent/journal_entries", %{
               entry_date: date,
               title: "Morning in Alfama",
               place_name: "Lisbon",
               lat: 38.7,
               lng: -9.1
             })
             |> json_response(200)

    # upsert is idempotent by date
    assert %{"ok" => true} =
             conn
             |> post(~p"/api/agent/journal_entries", %{entry_date: date, title: "Revised title"})
             |> json_response(200)

    assert %{"ok" => true, "section_count" => 2} =
             conn
             |> put(~p"/api/agent/journal_entries/#{date}/sections", %{
               sections: [
                 %{kind: "description", body: "Steep streets, tiled walls."},
                 %{kind: "poem", title: "Tram 28", body: "yellow tram, patient hill"}
               ]
             })
             |> json_response(200)

    assert %{"ok" => true} =
             conn
             |> post(~p"/api/agent/journal_entries/#{date}/publish", %{})
             |> json_response(200)

    entry = Journal.get_entry(poet.id, Date.utc_today())
    assert entry.status == "published"
    assert entry.title == "Revised title"
  end

  test "POST /location moves the poet and appends a path point", %{conn: conn, poet: poet} do
    assert %{"ok" => true, "place_name" => "Sintra, Portugal"} =
             conn
             |> post(~p"/api/agent/location", %{
               lat: 38.8029,
               lng: -9.3817,
               place_name: "Sintra, Portugal",
               country_code: "PT"
             })
             |> json_response(200)

    points = TravelingPoet.Poets.list_path_points(poet.id)
    assert length(points) == 1
    assert hd(points).place_name == "Sintra, Portugal"
  end

  test "illustration generation validates prompt and config", %{conn: conn} do
    # no IMAGE_GEN_API_KEY in test env -> 503, never a crash
    assert %{"error" => _} =
             conn
             |> post(~p"/api/agent/illustrations", %{prompt: "a watercolor of Lisbon"})
             |> json_response(503)

    assert %{"error" => _} =
             conn |> post(~p"/api/agent/illustrations", %{}) |> json_response(422)
  end

  test "rejects bad dates", %{conn: conn} do
    assert %{"error" => _} =
             conn
             |> post(~p"/api/agent/journal_entries", %{entry_date: "not-a-date"})
             |> json_response(422)
  end
end
