defmodule TravelingPoetWeb.ItemsTest do
  use TravelingPoetWeb.ConnCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Discover, Guide, Repo, Spaces}
  alias TravelingPoet.Guide.Place
  alias TravelingPoet.Spaces.{Item, JsonLd, Public}

  @weaving "crafts-and-design/textiles/weaving-and-silk"

  defp on_the_road(name, attrs \\ %{}) do
    poet_fixture(
      user_fixture(),
      Map.merge(%{name: name, is_public: true, status: "active"}, attrs)
    )
  end

  defp page(poet, date, place_name) do
    published_entry_fixture(poet, %{
      entry_date: date,
      title: "#{poet.name} #{date}",
      place_name: place_name,
      lat: 35.0,
      lng: 135.7
    })
  end

  defp put_places(entry, attrs) do
    {:ok, places} = Guide.replace_places(entry, attrs)
    places
  end

  defp tag(place, topic) do
    place
    |> Place.topics_changeset(%{
      topic: topic,
      topics_classified_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update!()
    |> TravelingPoet.Spaces.Ingest.topics_tagged()
  end

  setup do
    nam = on_the_road("Nam")

    {:ok, nam} =
      TravelingPoet.Poets.move_to(nam, %{
        lat: 35.01,
        lng: 135.77,
        place_name: "Kyoto, Kyoto Prefecture, Japan",
        country_code: "JP"
      })

    hilda = on_the_road("Hilda", %{is_public: false})

    [okutan, yudofu, matsuri] =
      put_places(page(nam, ~D[2026-09-01], "Kyoto"), [
        %{
          name: "Okutan",
          category: "restaurant",
          lat: 35.02,
          lng: 135.79,
          geocode_status: "ok",
          blurb: "Yudofu under the maples."
        },
        %{name: "Yudofu", category: "restaurant", kind: "dish"},
        %{
          name: "Gion Matsuri",
          category: "event",
          starts_on: ~D[2026-07-01],
          ends_on: ~D[2026-07-31],
          lat: 35.0,
          lng: 135.77,
          geocode_status: "ok"
        }
      ])

    tag(okutan, @weaving)

    %{made: 1} =
      TravelingPoet.Spaces.Ingest.sync_links(
        TravelingPoet.Journal.get_entry(nam.id, ~D[2026-09-01]),
        [okutan, yudofu],
        [%{"name" => "Yudofu", "links" => [%{"relation" => "at", "target" => "Okutan"}]}]
      )

    # Hilda's own find, and her row on Okutan: neither shows
    [secret] =
      put_places(page(hilda, ~D[2026-09-02], "Kyoto"), [
        %{name: "Secret Shed", category: "shop", lat: 35.03, lng: 135.78, geocode_status: "ok"},
        %{name: "Okutan", category: "restaurant"}
      ])
      |> Enum.take(1)

    %{nam: nam, hilda: hilda, okutan: okutan, yudofu: yudofu, matsuri: matsuri, secret: secret}
  end

  test "an item page says what it is, who found it, and carries its JSON-LD", %{
    conn: conn,
    okutan: okutan
  } do
    item = Spaces.get_item(okutan.item_id)
    html = conn |> get(~p"/items/#{item.slug}") |> html_response(200)

    assert html =~ "Okutan"
    assert html =~ "restaurant"
    assert html =~ "Found by Nam"
    refute html =~ "Hilda"
    assert html =~ "Yudofu under the maples."
    assert html =~ "here:"
    assert html =~ "Weaving"
    assert html =~ ~s(type="application/ld+json">)
    assert html =~ ~s("@type":"Restaurant")
  end

  test "the JSON-LD document alone, typed by kind, with the poet's links as properties", %{
    conn: conn,
    okutan: okutan,
    yudofu: yudofu,
    matsuri: matsuri
  } do
    conn = put_req_header(conn, "accept", "*/*")

    data =
      conn |> get(~p"/items/#{Spaces.get_item(yudofu.item_id).slug}/jsonld") |> json_response(200)

    assert data["@type"] == "MenuItem"
    assert data["location"]["name"] == "Okutan"
    assert data["location"]["@id"] =~ "/items/okutan"

    assert [%{"@type" => "Person", "name" => "Nam", "url" => url}] = data["tp:foundBy"]
    assert url =~ "/p/"

    event =
      conn
      |> get(~p"/items/#{Spaces.get_item(matsuri.item_id).slug}/jsonld")
      |> json_response(200)

    assert event["@type"] == "Event"
    assert {event["startDate"], event["endDate"]} == {"2026-07-01", "2026-07-31"}
    assert event["geo"]["latitude"] == 35.0
    assert event["address"]["addressCountry"] == "JP"
    assert event["containedInPlace"]["@type"] == "City"

    assert conn
           |> get(~p"/items/#{Spaces.get_item(okutan.item_id).slug}/jsonld")
           |> response_content_type(:"ld+json") =~ "ld+json"
  end

  test "a private poet's item has no page; a merged slug redirects for good", %{
    conn: conn,
    secret: secret,
    okutan: okutan
  } do
    assert conn |> get(~p"/items/#{Spaces.get_item(secret.item_id).slug}") |> html_response(404)

    assert conn
           |> put_req_header("accept", "*/*")
           |> get(~p"/items/#{Spaces.get_item(secret.item_id).slug}/jsonld")
           |> json_response(404)

    assert conn |> get(~p"/items/no-such-thing") |> html_response(404)

    {:ok, gone} = Spaces.create_item(%{kind: "place", name: "Okutan Tofu"})
    gone |> Item.changeset(%{status: "merged", merged_into_id: okutan.item_id}) |> Repo.update!()
    conn = get(conn, ~p"/items/okutan-tofu")
    assert redirected_to(conn, 301) == "/items/#{Spaces.get_item(okutan.item_id).slug}"
  end

  test "the GeoJSON feed: mapped public items, filtered by kind, topic and country, no cities", %{
    conn: conn
  } do
    conn = put_req_header(conn, "accept", "*/*")
    all = conn |> get(~p"/items.geojson") |> json_response(200)
    names = all["features"] |> Enum.map(& &1["properties"]["name"]) |> Enum.sort()
    # Okutan, Yudofu (its restaurant's pin), Gion Matsuri; not Secret Shed, not Kyoto
    assert names == ["Gion Matsuri", "Okutan", "Yudofu"]
    assert all["type"] == "FeatureCollection"
    okutan = Enum.find(all["features"], &(&1["properties"]["name"] == "Okutan"))
    assert okutan["geometry"] == %{"type" => "Point", "coordinates" => [135.79, 35.02]}
    assert okutan["properties"]["found_by"] == 1
    assert okutan["properties"]["country"] == "JP"

    assert [%{"properties" => %{"kind" => "event"}}] =
             (conn |> get(~p"/items.geojson?kind=event") |> json_response(200))["features"]

    assert [%{"properties" => %{"name" => "Okutan"}}] =
             (conn
              |> get(~p"/items.geojson?topic=crafts-and-design")
              |> json_response(200))["features"]

    assert [] == (conn |> get(~p"/items.geojson?country=PT") |> json_response(200))["features"]

    assert 3 ==
             length(
               (conn
                |> get(~p"/items.geojson?country=jp")
                |> json_response(200))["features"]
             )
  end

  test "Discover's place overview links to the item page", %{okutan: okutan} do
    assert Discover.place(okutan.id).item_slug == Spaces.get_item(okutan.item_id).slug
  end

  test "JsonLd.type/1 follows the kind and, for a place, its subkind" do
    assert JsonLd.type(%{kind: "place", subkind: "museum"}) == "Museum"
    assert JsonLd.type(%{kind: "place", subkind: "attraction"}) == "Place"
    assert JsonLd.type(%{kind: "person", subkind: nil}) == "Person"
    assert JsonLd.type(%{kind: "work", subkind: "book"}) == "CreativeWork"
    assert JsonLd.type(%{kind: "mystery", subkind: nil}) == "Thing"
  end

  test "Public.lookup/1 follows the rule: public once a public poet published it", %{
    okutan: okutan,
    secret: secret
  } do
    assert {:ok, _} = Public.lookup(Spaces.get_item(okutan.item_id).slug)
    assert :none == Public.lookup(Spaces.get_item(secret.item_id).slug)
    assert :none == Public.lookup("nothing")
  end
end
