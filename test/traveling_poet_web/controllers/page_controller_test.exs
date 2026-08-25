defmodule TravelingPoetWeb.PageControllerTest do
  use TravelingPoetWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "A poet wanders the world for you"
  end
end
