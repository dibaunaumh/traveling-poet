defmodule TravelingPoetWeb.MapsExportTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Bookmarks, MapsLinks}

  defp signed_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  describe "google_url/1" do
    test "by name and address, else by coordinates, else none" do
      assert MapsLinks.google_url(%{name: "Lody", address: "Krakowska 1, Kraków"}) ==
               "https://www.google.com/maps/search/?api=1&query=Lody%2C+Krakowska+1%2C+Krak%C3%B3w"

      assert MapsLinks.google_url(%{name: "Lody", address: nil, lat: 50.05, lng: 19.94}) =~
               "query=50.05%2C19.94"

      assert MapsLinks.google_url(%{name: "Lody", address: nil, lat: nil, lng: nil}) == nil
    end
  end

  test "the KML carries only places with coordinates, escaped" do
    kml =
      MapsLinks.kml(
        [
          %{name: "Bread & <Butter>", lat: 50.05, lng: 19.94, blurb: "Croissants", address: nil},
          %{name: "Nowhere", lat: nil, lng: nil}
        ],
        "Saved"
      )

    assert kml =~ "<name>Bread &amp; &lt;Butter&gt;</name>"
    assert kml =~ "<coordinates>19.94,50.05</coordinates>"
    refute kml =~ "Nowhere"
  end

  describe "a reader's saved places" do
    setup do
      reader = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
      poet = poet_fixture(reader)
      entry = published_entry_fixture(poet)

      cafe =
        place_fixture(poet, entry, %{
          name: "Charlotte",
          address: "plac Szczepański 2, Kraków",
          lat: 50.0646,
          lng: 19.9358
        })

      {:ok, _} = Bookmarks.toggle(reader.id, "place", cafe.id)
      %{reader: reader, cafe: cafe}
    end

    test "download as KML for Google My Maps", %{conn: conn, reader: reader} do
      conn = get(signed_in(conn, reader), ~p"/guide/saved.kml")

      assert get_resp_header(conn, "content-disposition") |> hd() =~ "attachment"
      body = response(conn, 200)
      assert body =~ "<name>Charlotte</name>"
      assert body =~ "<coordinates>19.9358,50.0646</coordinates>"
    end

    test "someone else's saves are not in it", %{conn: conn} do
      stranger = user_fixture()
      body = conn |> signed_in(stranger) |> get(~p"/guide/saved.kml") |> response(200)
      refute body =~ "Charlotte"
    end

    test "the Saved view offers the download and each place opens in Google Maps",
         %{conn: conn, reader: reader, cafe: cafe} do
      {:ok, view, _html} = live(signed_in(conn, reader), ~p"/guide?saved=1")

      assert has_element?(view, ~s(#saved-to-maps a[href="/guide/saved.kml"]))
      assert has_element?(view, "#maps-#{cafe.id}[href^=\"https://www.google.com/maps/search/\"]")
    end
  end
end
