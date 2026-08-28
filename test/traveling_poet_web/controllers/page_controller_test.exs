defmodule TravelingPoetWeb.PageControllerTest do
  use TravelingPoetWeb.ConnCase

  import TravelingPoet.Fixtures

  test "GET / signed out shows the hero and sign-up CTAs", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    assert html =~ "Your personal travel scout."
    assert html =~ "Start exploring"
    assert html =~ "Send out your poet"
    # no poets yet: the empty-state line, not a "0 poets" count
    assert html =~ "still lacing their boots"
    refute html =~ "0 poets exploring"
  end

  test "GET / signed in hides sign-up CTAs and links to the journal", %{conn: conn} do
    user = user_fixture()
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    html = conn |> get(~p"/") |> html_response(200)
    assert html =~ "Open your journal"
    refute html =~ "Send out your poet"
    refute html =~ "Scout a trip"
    refute html =~ "/auth/google"
  end
end
