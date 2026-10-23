defmodule TravelingPoetWeb.NearHomeApiTest do
  use TravelingPoetWeb.ConnCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, NearHome, Provisioner}

  setup %{conn: conn} do
    Req.Test.stub(TravelingPoet.LinkCheck, fn conn ->
      if conn.request_path =~ "dead",
        do: Plug.Conn.send_resp(conn, 404, "gone"),
        else: Req.Test.text(conn, "ok")
    end)

    user = agent_user_fixture()

    {:ok, user} =
      Accounts.update_user(user, %{
        home_place_name: "Lisbon, Portugal",
        home_lat: 38.7223,
        home_lng: -9.1393
      })

    poet = poet_fixture(user)

    authed =
      conn
      |> put_req_header("authorization", "Bearer #{user.agent_api_token}")
      |> put_req_header("content-type", "application/json")

    %{conn: authed, anon: conn, user: user, poet: poet}
  end

  defp pick(attrs) do
    Map.merge(
      %{
        name: "Feira da Ladra",
        url: "https://example.com/feira",
        kind: "market",
        starts_on: Date.to_iso8601(Date.utc_today()),
        address: "Campo de Santa Clara, Lisbon",
        lat: 38.7148,
        lng: -9.1263,
        blurb: "Old prints and tiles."
      },
      attrs
    )
  end

  test "the poet's tool is registered and posts here" do
    assert "near_home_put" in Provisioner.tpoet_plugin_tools()
    assert Provisioner.tpoet_plugin_source("", "") =~ ~s("/api/agent/near_home")
  end

  test "needs the agent's token", %{anon: anon} do
    assert anon |> post(~p"/api/agent/near_home", %{picks: []}) |> json_response(401)
  end

  test "keeps the good picks and names what it dropped, and why", %{conn: conn, user: user} do
    body =
      conn
      |> post(~p"/api/agent/near_home", %{
        picks: [pick(%{}), pick(%{name: "Gone", url: "https://example.com/dead"})]
      })
      |> json_response(200)

    assert body["ok"]
    assert body["kept"] == 1
    assert [%{"name" => "Gone", "reason" => reason}] = body["dropped"]
    assert reason =~ "dead"
    assert body["note"] =~ "send the WHOLE list again"
    assert [%{name: "Feira da Ladra"}] = NearHome.latest(user.id)
  end

  test "all dropped is a 422 with the reasons, and nothing stored", %{conn: conn, user: user} do
    body =
      conn
      |> post(~p"/api/agent/near_home", %{picks: [pick(%{url: "https://example.com/dead"})]})
      |> json_response(422)

    refute body["ok"]
    assert [%{"reason" => _}] = body["dropped"]
    assert NearHome.latest(user.id) == []
  end

  test "a reader with no home is refused", %{conn: conn, user: user} do
    {:ok, _} = Accounts.update_user(user, %{home_lat: nil, home_lng: nil})

    body = conn |> post(~p"/api/agent/near_home", %{picks: [pick(%{})]}) |> json_response(409)
    assert body["note"] =~ "do not look near home"
  end

  test "picks must be a list", %{conn: conn} do
    assert conn |> post(~p"/api/agent/near_home", %{picks: "x"}) |> json_response(422)
  end
end
