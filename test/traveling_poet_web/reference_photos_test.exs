defmodule TravelingPoetWeb.ReferencePhotosTest do
  use TravelingPoetWeb.ConnCase, async: false

  import TravelingPoet.Fixtures

  setup %{conn: conn} do
    user = agent_user_fixture()
    poet_fixture(user)
    %{conn: put_req_header(conn, "authorization", "Bearer #{user.agent_api_token}"), anon: conn}
  end

  test "needs the agent token", %{anon: anon} do
    assert anon |> get(~p"/api/agent/reference_photos?query=x") |> json_response(401)
  end

  test "returns Commons file pages, parsing the query string numbers", %{conn: conn} do
    Req.Test.stub(TravelingPoet.Commons, fn conn ->
      assert conn.query_params["ggscoord"] == "38.71|-9.14"
      assert conn.query_params["ggslimit"] == "3"

      Req.Test.json(conn, %{
        "query" => %{
          "pages" => [
            %{
              "index" => 1,
              "title" => "File:Tram 28.jpg",
              "imageinfo" => [
                %{
                  "mime" => "image/jpeg",
                  "descriptionurl" => "https://commons.wikimedia.org/wiki/File:Tram_28.jpg"
                }
              ]
            }
          ]
        }
      })
    end)

    body =
      conn
      |> get(~p"/api/agent/reference_photos?lat=38.71&lng=-9.14&limit=3")
      |> json_response(200)

    assert [%{"page_url" => "https://commons.wikimedia.org/wiki/File:Tram_28.jpg"}] =
             body["photos"]

    assert body["note"] =~ "page_url"
  end

  test "an empty result says how to widen the search", %{conn: conn} do
    Req.Test.stub(TravelingPoet.Commons, &Req.Test.json(&1, %{"batchcomplete" => true}))
    body = conn |> get(~p"/api/agent/reference_photos?query=nowhere") |> json_response(200)
    assert body["photos"] == []
    assert body["note"] =~ "lat/lng"
  end

  test "no query and no coordinates is a 422", %{conn: conn} do
    assert conn |> get(~p"/api/agent/reference_photos") |> json_response(422)
  end
end
