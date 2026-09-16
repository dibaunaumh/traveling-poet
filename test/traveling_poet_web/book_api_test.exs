defmodule TravelingPoetWeb.BookApiTest do
  use TravelingPoetWeb.ConnCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Books, Journal, Poets}

  setup %{conn: conn} do
    user = agent_user_fixture(%{credits: 10, name: "Udi Bauman"})
    poet = poet_fixture(user, %{name: "Wren"})
    {:ok, _} = Poets.move_to(poet, %{lat: 38.72, lng: -9.13, place_name: "Lisbon, Portugal"})
    entry = published_entry_fixture(poet, %{title: "Trams", teaser: "Hills, taken personally"})

    {:ok, _} =
      Journal.replace_sections(entry, [
        %{
          kind: "description",
          body: "Lisbon is built on hills and the trams take them personally."
        },
        %{
          kind: "poem",
          title: "Tram 28",
          body: "Yellow box, iron song,\nyou take the hill the way"
        }
      ])

    authed =
      conn
      |> put_req_header("authorization", "Bearer #{user.agent_api_token}")
      |> put_req_header("content-type", "application/json")

    %{conn: authed, anon: conn, user: user, poet: poet, entry: entry}
  end

  test "needs the agent's token", %{anon: anon} do
    assert anon |> get(~p"/api/agent/book_context") |> json_response(401)
    assert anon |> put(~p"/api/agent/book/matter", %{}) |> json_response(401)
  end

  test "both answer 409 with a pointer to Settings when nothing was paid for", %{conn: conn} do
    body = conn |> get(~p"/api/agent/book_context") |> json_response(409)
    assert body["error"] == "no book composition is open"
    assert body["note"] =~ "Settings"

    assert conn
           |> put(~p"/api/agent/book/matter", %{"dedication" => "free?"})
           |> json_response(409)
  end

  test "context gives the chapters, the days and the exact quotable lines",
       %{conn: conn, user: user, poet: poet, entry: entry} do
    {:ok, edition} = Books.request_composition(user, poet)
    body = conn |> get(~p"/api/agent/book_context") |> json_response(200)

    assert body["edition_id"] == edition.id
    assert body["companion"] == "Udi"
    assert body["poet"]["name"] == "Wren"
    assert body["journey"]["days"] == 1
    assert body["limits"]["foreword"] == 2500
    assert body["limits"]["pull_quotes"] == 8

    [chapter] = body["chapters"]
    assert chapter["key"] == Integer.to_string(Poets.current_path_point(poet.id).id)
    assert chapter["title"] == "Lisbon, Portugal"

    [day] = chapter["day_pages"]
    assert day["entry_date"] == Date.to_iso8601(entry.entry_date)
    assert day["title"] == "Trams"
    assert day["teaser"] == "Hills, taken personally"
    assert day["poem_title"] == "Tram 28"
    assert day["quotable_poem_lines"] == ["Yellow box, iron song,", "you take the hill the way"]

    assert day["quotable_sentences"] == [
             "Lisbon is built on hills and the trams take them personally."
           ]
  end

  test "put_matter saves, verifies quotes, and says what is still missing",
       %{conn: conn, user: user, poet: poet, entry: entry} do
    {:ok, _edition} = Books.request_composition(user, poet)
    key = Integer.to_string(Poets.current_path_point(poet.id).id)
    date = Date.to_iso8601(entry.entry_date)

    body =
      conn
      |> put(~p"/api/agent/book/matter", %{
        "dedication" => "For Udi",
        "foreword" => String.duplicate("x", 2600),
        "pull_quotes" => [
          %{"entry_date" => date, "text" => "you take the hill the way"},
          %{"entry_date" => date, "text" => "you take the hills like a goat"}
        ]
      })
      |> json_response(200)

    assert body["written"] == ["dedication", "pull_quotes"]
    assert body["rejected"] == %{"foreword" => "longer than 2500 characters"}
    assert [%{"text" => "you take the hill the way"}] = body["accepted_quotes"]
    assert [%{"reason" => reason}] = body["dropped_quotes"]
    assert reason =~ "word for word"
    assert body["missing_openers"] == [key]
    refute body["complete"]

    body =
      conn
      |> put(~p"/api/agent/book/matter", %{"chapter_openers" => %{key => "Lisbon first."}})
      |> json_response(200)

    assert body["missing_openers"] == []
    assert body["complete"]
  end
end
