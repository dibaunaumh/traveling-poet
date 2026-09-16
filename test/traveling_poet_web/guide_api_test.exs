defmodule TravelingPoetWeb.GuideApiTest do
  use TravelingPoetWeb.ConnCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Guide, Journal}

  setup %{conn: conn} do
    user = agent_user_fixture()
    poet = poet_fixture(user)

    authed =
      conn
      |> put_req_header("authorization", "Bearer #{user.agent_api_token}")
      |> put_req_header("content-type", "application/json")

    %{conn: authed, user: user, poet: poet}
  end

  defp today, do: Date.utc_today()

  defp with_entry(poet) do
    {:ok, entry} =
      Journal.upsert_entry(poet.id, today(), %{
        title: "A day",
        place_name: "Lisbon, Portugal"
      })

    entry
  end

  defp place(name, extra \\ %{}) do
    Map.merge(%{"name" => name, "category" => "restaurant"}, extra)
  end

  defp put_places(conn, places) do
    put(conn, ~p"/api/agent/journal_entries/#{Date.to_iso8601(today())}/places", %{
      "places" => places
    })
  end

  test "round-trips a day's places and returns their ids", %{conn: conn, poet: poet} do
    with_entry(poet)

    body =
      conn
      |> put_places([place("Tasca do Chico"), place("Miradouro", %{"category" => "viewpoint"})])
      |> json_response(200)

    assert body["ok"]
    assert body["place_count"] == 2
    assert Map.keys(body["place_ids"]) |> Enum.sort() == ["Miradouro", "Tasca do Chico"]
    assert length(Guide.list_places(poet.id, published_only: false)) == 2
  end

  test "is idempotent by date — a re-put replaces rather than accumulating", %{
    conn: conn,
    poet: poet
  } do
    with_entry(poet)

    put_places(conn, [place("Tasca do Chico")]) |> json_response(200)
    put_places(conn, [place("Tasca do Chico")]) |> json_response(200)

    assert length(Guide.list_places(poet.id, published_only: false)) == 1
  end

  # Same coaching shape as put_sections: tell the model what to call first
  # rather than just refusing.
  test "places for a date with no entry get told to upsert first", %{conn: conn} do
    body = conn |> put_places([place("Tasca do Chico")]) |> json_response(404)
    assert body["error"] =~ "journal_upsert_entry"
  end

  test "a bad date is refused before anything is written", %{conn: conn} do
    assert conn
           |> put(~p"/api/agent/journal_entries/not-a-date/places", %{"places" => []})
           |> json_response(422)
  end

  test "places must be a list", %{conn: conn, poet: poet} do
    with_entry(poet)

    assert conn
           |> put(~p"/api/agent/journal_entries/#{Date.to_iso8601(today())}/places", %{
             "places" => "Tasca do Chico"
           })
           |> json_response(422)
  end

  # Refusing eight good recommendations to punish one dead link is a worse
  # outcome than dropping the one. The response names it so the model can fix
  # it next run.
  test "a place with an unreachable link is dropped while the rest are saved", %{
    conn: conn,
    poet: poet
  } do
    with_entry(poet)

    body =
      conn
      |> put_places([
        place("Tasca do Chico"),
        # A blocked host: LinkCheck rejects it on inspection, with no network
        # I/O, so this assertion never depends on the internet.
        place("Ghost Bar", %{"source_url" => "http://localhost:9/nope"}),
        place("Miradouro", %{"category" => "viewpoint"})
      ])
      |> json_response(200)

    assert body["dropped"] == ["Ghost Bar"]
    assert body["place_count"] == 2

    names = Guide.list_places(poet.id, published_only: false) |> Enum.map(& &1.name)
    assert Enum.sort(names) == ["Miradouro", "Tasca do Chico"]
  end

  test "retrying one dropped place alone never erases the places already saved", %{
    conn: conn,
    poet: poet
  } do
    with_entry(poet)

    put_places(conn, [place("Tasca do Chico"), place("Miradouro", %{"category" => "viewpoint"})])
    |> json_response(200)

    body =
      conn
      |> put_places([place("Ghost Bar", %{"source_url" => "http://localhost:9/nope"})])
      |> json_response(200)

    assert body["kept_existing"] == true
    assert body["place_count"] == 2
    assert body["dropped"] == ["Ghost Bar"]
    assert length(Guide.list_places(poet.id, published_only: false)) == 2
  end

  describe "one place, once per stay" do
    alias TravelingPoet.Poets

    # yesterday's published entry in the stay the poet is on, with its places
    defp yesterday_with(poet, places) do
      {:ok, _} = Poets.move_to(poet, %{lat: 25.57, lng: 91.88, place_name: "Shillong, India"})
      entry = published_entry_fixture(poet, %{entry_date: Date.add(today(), -1)})
      {:ok, _} = Guide.replace_places(entry, places)
      entry
    end

    test "a place or event logged on an earlier day is not logged again, however spelled",
         %{conn: conn, poet: poet} do
      yesterday_with(poet, [
        place("Dylan's Cafe", %{"category" => "cafe"}),
        place("Autumn Festival", %{"category" => "event"})
      ])

      with_entry(poet)

      body =
        conn
        |> put_places([
          place("Dylan's Café", %{"category" => "cafe"}),
          place("AUTUMN festival!", %{"category" => "event"}),
          place("Police Bazaar", %{"category" => "shop"})
        ])
        |> json_response(200)

      assert body["place_count"] == 1
      assert body["already_logged"] == ["Dylan's Café", "AUTUMN festival!"]
      assert Map.keys(body["place_ids"]) == ["Police Bazaar"]
    end

    test "the same place twice in one list is saved once", %{conn: conn, poet: poet} do
      with_entry(poet)

      body =
        conn
        |> put_places([place("Cafe Aloha"), place("CAFÉ ALOHA")])
        |> json_response(200)

      assert body["place_count"] == 1
      assert body["already_logged"] == ["CAFÉ ALOHA"]
    end

    test "a list of nothing but repeats leaves today's places as they were",
         %{conn: conn, poet: poet} do
      yesterday_with(poet, [place("Dylan's Cafe")])
      with_entry(poet)
      put_places(conn, [place("Police Bazaar")]) |> json_response(200)

      body = conn |> put_places([place("dylans cafe")]) |> json_response(200)

      assert body["kept_existing"] == true
      assert body["already_logged"] == ["dylans cafe"]
      assert body["place_count"] == 1
    end

    test "the morning context lists this stay's places from earlier days, not today's",
         %{conn: conn, poet: poet} do
      yesterday_with(poet, [
        place("Dylan's Cafe", %{"category" => "cafe"}),
        place("Autumn Festival", %{"category" => "event"})
      ])

      with_entry(poet)
      put_places(conn, [place("Police Bazaar")]) |> json_response(200)

      body = conn |> get(~p"/api/agent/context") |> json_response(200)
      names = Enum.map(body["guide"]["this_stay"], & &1["name"])
      assert names == ["Dylan's Cafe", "Autumn Festival"]
      assert hd(body["guide"]["this_stay"])["logged_on"] == Date.to_iso8601(Date.add(today(), -1))
    end
  end

  test "a runaway list is capped and the agent is told how much was cut", %{
    conn: conn,
    poet: poet
  } do
    with_entry(poet)

    body =
      conn
      |> put_places(for i <- 1..12, do: place("Place #{i}"))
      |> json_response(200)

    assert body["place_count"] == 8
    assert body["over_cap"] == 4
  end

  test "an unfindable place is saved and reported, not rejected", %{conn: conn, poet: poet} do
    with_entry(poet)

    body = conn |> put_places([place("Nameless viewpoint")]) |> json_response(200)

    # Geocoding is off in test, so everything reports as unlocated — the point
    # is that the place is still saved and still listed.
    assert body["not_located"] == ["Nameless viewpoint"]
    assert body["place_count"] == 1
    assert length(Guide.list_places(poet.id, published_only: false)) == 1
  end

  test "one poet cannot write places onto another's entry", %{conn: conn} do
    other = poet_fixture(agent_user_fixture())
    with_entry(other)

    assert conn |> put_places([place("Tasca do Chico")]) |> json_response(404)
  end

  describe "place illustrations" do
    # unattached_illustrations/2 renders any entry-linked illustration that no
    # section claims. A place drawing linked to the entry would therefore show
    # up as a stray taped photo in the middle of the journal page.
    test "a place drawing attaches to the place and never leaks onto the journal page", %{
      poet: poet
    } do
      entry = with_entry(poet)
      {:ok, [place]} = Guide.replace_places(entry, [place("Tasca do Chico")])

      media = media_fixture(poet)
      {:ok, _} = Guide.attach_media(place, media.id)

      entry = Journal.preload_entry(entry)
      assert Journal.unattached_illustrations(entry, entry.sections) == []
    end

    test "an entry illustration still surfaces as before", %{poet: poet} do
      entry = with_entry(poet)
      media_fixture(poet, %{journal_entry_id: entry.id})

      entry = Journal.preload_entry(entry)
      assert [_one] = Journal.unattached_illustrations(entry, entry.sections)
    end
  end
end
