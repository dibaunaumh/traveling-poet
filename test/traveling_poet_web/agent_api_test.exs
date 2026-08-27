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

  test "rejects re-uploading byte-identical illustrations", %{conn: conn, poet: poet} do
    bytes = :crypto.strong_rand_bytes(64)
    hash = :crypto.hash(:md5, bytes) |> Base.encode16()

    {:ok, _existing} =
      Journal.create_media(%{
        poet_id: poet.id,
        s3_key: "poets/#{poet.id}/media/original.png",
        content_type: "image/png",
        kind: "illustration",
        content_hash: hash,
        sources: %{"items" => [%{"url" => "https://example.com/x", "label" => "x"}]}
      })

    # duplicate check fires before any storage call, so no S3 needed
    assert %{"error" => error} =
             conn
             |> post(~p"/api/agent/media", %{
               image_base64: Base.encode64(bytes),
               content_type: "image/png",
               kind: "illustration",
               sources: [%{url: "https://example.com/x", label: "x"}]
             })
             |> json_response(422)

    assert error =~ "byte-identical"
  end

  test "scout context exposes itinerary; location marks stop visited", %{conn: conn, poet: poet} do
    {:ok, _} =
      TravelingPoet.Poets.update_poet(poet, %{
        settings: Map.put(poet.settings || %{}, "mode", "scout")
      })

    {:ok, s1} =
      TravelingPoet.Poets.add_stop(poet.id, %{place_name: "Porto", lat: 41.15, lng: -8.61})

    {:ok, _s2} =
      TravelingPoet.Poets.add_stop(poet.id, %{place_name: "Coimbra", lat: 40.2, lng: -8.42})

    body = conn |> get(~p"/api/agent/context") |> json_response(200)
    assert body["poet"]["mode"] == "scout"
    assert [%{"place_name" => "Porto"}, %{"place_name" => "Coimbra"}] = body["itinerary"]
    assert body["next_stop"]["id"] == s1.id

    assert %{"ok" => true, "itinerary_stop_visited" => visited_id} =
             conn
             |> post(~p"/api/agent/location", %{
               lat: 41.15,
               lng: -8.61,
               place_name: "Porto, Portugal",
               itinerary_stop_id: s1.id
             })
             |> json_response(200)

    assert visited_id == s1.id
    assert TravelingPoet.Poets.next_pending_stop(poet.id).place_name == "Coimbra"
  end

  test "wander context has empty itinerary", %{conn: conn} do
    body = conn |> get(~p"/api/agent/context") |> json_response(200)
    assert body["poet"]["mode"] == "wander"
    assert body["itinerary"] == []
    assert body["next_stop"] == nil
  end
end
