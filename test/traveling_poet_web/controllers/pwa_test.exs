defmodule TravelingPoetWeb.PwaTest do
  use TravelingPoetWeb.ConnCase

  test "the web app manifest is served with its own media type", %{conn: conn} do
    conn = get(conn, ~p"/manifest.webmanifest")
    assert conn.status == 200
    assert [type] = get_resp_header(conn, "content-type")
    assert type =~ "application/manifest+json"

    manifest = Jason.decode!(conn.resp_body)
    assert manifest["display"] == "standalone"
    assert manifest["start_url"] == "/"

    for %{"src" => src} <- manifest["icons"] do
      assert get(conn, src).status == 200, "manifest icon #{src} is missing"
    end
  end

  test "pages link the manifest and the iOS home-screen icon", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    assert html =~ ~s(<link rel="manifest" href="/manifest.webmanifest")
    assert html =~ ~s(<link rel="apple-touch-icon" href="/images/apple-touch-icon.png")
    assert html =~ ~s(<meta name="apple-mobile-web-app-capable" content="yes")
    assert html =~ "viewport-fit=cover"
  end
end
