defmodule TravelingPoetWeb.DeadLinksApiTest do
  use TravelingPoetWeb.ConnCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.Journal

  setup %{conn: conn} do
    user = agent_user_fixture()
    poet = poet_fixture(user)

    Req.Test.stub(TravelingPoet.LinkCheck, fn conn ->
      if conn.host == "dead.example",
        do: Plug.Conn.send_resp(conn, 404, "gone"),
        else: Req.Test.text(conn, "ok")
    end)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{user.agent_api_token}")
      |> put_req_header("content-type", "application/json")

    %{conn: conn, poet: poet, date: Date.to_iso8601(Date.utc_today())}
  end

  test "dead grounding sources are dropped and named; the entry is saved", ctx do
    body =
      ctx.conn
      |> post(~p"/api/agent/journal_entries", %{
        "entry_date" => ctx.date,
        "title" => "Swifts over the harbour",
        "sources" => %{
          "items" => [
            %{"url" => "https://live.example/wiki", "label" => "Wikipedia"},
            %{"url" => "https://dead.example/gone", "label" => "Old guide"}
          ]
        }
      })
      |> json_response(200)

    assert body["dropped_dead_sources"] == ["https://dead.example/gone"]
    assert body["note"] =~ "unreachable"

    entry = Journal.get_entry_preloaded(ctx.poet.id, Date.utc_today())

    assert entry.sources["items"] == [
             %{"url" => "https://live.example/wiki", "label" => "Wikipedia"}
           ]
  end

  test "all-live sources add nothing to the reply", ctx do
    body =
      ctx.conn
      |> post(~p"/api/agent/journal_entries", %{
        "entry_date" => ctx.date,
        "sources" => %{"items" => [%{"url" => "https://live.example/wiki"}]}
      })
      |> json_response(200)

    refute Map.has_key?(body, "dropped_dead_sources")
    refute Map.has_key?(body, "note")
  end

  test "a dead link in prose loses its link, keeps its words, and is reported", ctx do
    ctx.conn
    |> post(~p"/api/agent/journal_entries", %{"entry_date" => ctx.date})
    |> json_response(200)

    body =
      ctx.conn
      |> put(~p"/api/agent/journal_entries/#{ctx.date}/sections", %{
        "sections" => [
          %{
            "kind" => "description",
            "body" =>
              "Lunch at [Casa Lola](https://dead.example/lola) by [the port](https://live.example/port)."
          }
        ]
      })
      |> json_response(200)

    assert body["unlinked_dead_links"] == ["https://dead.example/lola"]

    [section] = Journal.get_entry_preloaded(ctx.poet.id, Date.utc_today()).sections
    assert section.body == "Lunch at Casa Lola by [the port](https://live.example/port)."
  end
end
