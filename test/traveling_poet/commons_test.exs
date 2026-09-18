defmodule TravelingPoet.CommonsTest do
  use ExUnit.Case, async: true

  alias TravelingPoet.Commons

  defp page(index, title, opts \\ []) do
    %{
      "index" => index,
      "title" => "File:" <> title,
      "imageinfo" => [
        %{
          "mime" => Keyword.get(opts, :mime, "image/jpeg"),
          "descriptionurl" => "https://commons.wikimedia.org/wiki/File:" <> URI.encode(title),
          "thumburl" => "https://upload.wikimedia.org/thumb/" <> title,
          "width" => 2000,
          "height" => 1500,
          "extmetadata" => %{
            "ImageDescription" => %{"value" => "<p>The <b>street</b>\n in May</p>"},
            "Artist" => %{"value" => ~s(<a href="//commons.wikimedia.org/wiki/User:X">X</a>)},
            "LicenseShortName" => %{"value" => "CC BY-SA 4.0"}
          }
        }
      ]
    }
    |> then(fn p ->
      case Keyword.get(opts, :dist) do
        nil -> p
        d -> Map.put(p, "coordinates", [%{"lat" => 1.0, "lon" => 2.0, "dist" => d}])
      end
    end)
  end

  test "file pages come back in search order, bitmaps only, with plain-text metadata" do
    body = %{
      "query" => %{
        "pages" => [
          page(2, "B.jpg"),
          page(1, "A.jpg"),
          page(3, "Map.svg", mime: "image/svg+xml")
        ]
      }
    }

    assert [
             %{
               title: "A.jpg",
               page_url: "https://commons.wikimedia.org/wiki/File:A.jpg",
               description: "The street in May",
               author: "X",
               license: "CC BY-SA 4.0",
               width: 2000
             },
             %{title: "B.jpg"}
           ] = Commons.parse(body)

    assert Commons.parse(%{"batchcomplete" => true}) == []
  end

  test "web-search habits are stripped from the query" do
    assert Commons.clean_query(~s(site:commons.wikimedia.org "Ponte Vecchio" filetype:jpg)) ==
             ~s("Ponte Vecchio")

    assert Commons.clean_query("commons.wikimedia.org File: Kenilworth Aquatic Gardens") ==
             "Kenilworth Aquatic Gardens"

    assert Commons.clean_query(nil) == ""
  end

  test "a query and coordinates run both searches, merged without duplicates" do
    Req.Test.stub(TravelingPoet.Commons, fn conn ->
      params = conn.query_params
      assert conn |> Plug.Conn.get_req_header("user-agent") |> hd() =~ "TravelingPoet"

      pages =
        case params["generator"] do
          "search" ->
            assert params["gsrsearch"] == "Mezquita Cordoba filetype:bitmap"
            assert params["gsrnamespace"] == "6"
            [page(1, "Mezquita.jpg"), page(2, "Patio.jpg")]

          "geosearch" ->
            assert params["ggscoord"] == "37.87|-4.77"
            assert params["ggsradius"] == "500"
            [page(1, "Patio.jpg", dist: 40), page(2, "Door.jpg", dist: 120)]
        end

      Req.Test.json(conn, %{"query" => %{"pages" => pages}})
    end)

    assert {:ok, photos} =
             Commons.search("site:commons.wikimedia.org Mezquita Cordoba",
               lat: 37.87,
               lng: -4.77,
               radius_m: 500
             )

    assert Enum.map(photos, & &1.title) == ["Mezquita.jpg", "Patio.jpg", "Door.jpg"]
    assert %{distance_m: 120} = List.last(photos)
  end

  test "nothing to search for is refused without a request; an API failure is an error" do
    assert {:error, "a query or lat/lng is required"} = Commons.search("  site:x.org  ")

    Req.Test.stub(TravelingPoet.Commons, &Plug.Conn.send_resp(&1, 404, "gone"))
    assert {:error, "Commons API returned 404"} = Commons.search("Ponte Vecchio")
  end
end
