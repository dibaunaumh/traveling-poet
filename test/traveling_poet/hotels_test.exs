defmodule TravelingPoet.HotelsTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Hotels, Repo}
  alias TravelingPoet.Guide.StayArea
  alias TravelingPoet.Hotels.Rank

  # What LiteAPI's POST /hotels/rates answered for Kraków in the sandbox,
  # cut to two hotels.
  @rates %{
    "data" => [
      %{
        "hotelId" => "near",
        "roomTypes" => [
          %{"offerRetailRate" => %{"amount" => 300.0, "currency" => "EUR"}},
          %{"offerRetailRate" => %{"amount" => 240.0, "currency" => "EUR"}}
        ]
      },
      %{
        "hotelId" => "far",
        "roomTypes" => [%{"offerRetailRate" => %{"amount" => 150.0, "currency" => "EUR"}}]
      },
      %{"hotelId" => "unpriced", "roomTypes" => []}
    ],
    "hotels" => [
      %{
        "id" => "near",
        "name" => "Courtyard Rooms",
        "latitude" => 50.0515,
        "longitude" => 19.9466,
        "rating" => 9.5,
        "review_count" => 800,
        "stars" => 4,
        "thumbnail" => "https://x/near.jpg"
      },
      %{
        "id" => "far",
        "name" => "Ring Road Inn",
        "latitude" => 50.0900,
        "longitude" => 19.8800,
        "rating" => 7.1,
        "review_count" => 90,
        "stars" => 3
      },
      %{"id" => "unpriced", "name" => "No Rooms", "latitude" => 50.05, "longitude" => 19.94}
    ]
  }

  setup do
    Application.put_env(:traveling_poet, :liteapi_key, "sand_test")
    on_exit(fn -> Application.delete_env(:traveling_poet, :liteapi_key) end)
    :ok
  end

  test "search keeps priced hotels with coordinates, at the cheapest offer" do
    Req.Test.stub(Hotels, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body)["radius"] >= 1000
      Req.Test.json(conn, @rates)
    end)

    {:ok, hotels} = Hotels.search(%{lat: 50.05, lng: 19.94}, ~D[2026-11-10], ~D[2026-11-13])
    near = Enum.find(hotels, &(&1.id == "near"))

    assert length(hotels) == 2
    assert near.total == 240.0
    assert near.per_night == 80.0
  end

  test "no search without a key or with dates the wrong way round" do
    assert Hotels.search(%{lat: 1, lng: 1}, ~D[2026-11-13], ~D[2026-11-10]) ==
             {:error, :bad_dates}

    Application.delete_env(:traveling_poet, :liteapi_key)

    assert Hotels.search(%{lat: 1, lng: 1}, ~D[2026-11-10], ~D[2026-11-13]) ==
             {:error, :not_configured}
  end

  test "a hotel near the poet's places beats a cheaper one far from them" do
    hotels = Hotels.parse(@rates, 3)
    places = [%{lat: 50.0517, lng: 19.9470}, %{lat: 50.0509, lng: 19.9460}]
    areas = [%{name: "Kazimierz", lat: 50.0513, lng: 19.9465}]

    [first, second] = Rank.rank(hotels, places, areas)
    assert first.id == "near"
    assert first.near == 2
    assert first.area == "Kazimierz"
    assert second.near == 0
  end

  test "book links come from the white-label template, and only when it is set" do
    hotel = %{id: "lp1"}
    assert Hotels.booking_url(hotel, ~D[2026-11-10], ~D[2026-11-13], 2) == nil

    Application.put_env(
      :traveling_poet,
      :liteapi_booking_url,
      "https://hotels.example/hotels/{hotel_id}?checkin={checkin}&checkout={checkout}&adults={adults}"
    )

    on_exit(fn -> Application.delete_env(:traveling_poet, :liteapi_booking_url) end)

    assert Hotels.booking_url(hotel, ~D[2026-11-10], ~D[2026-11-13], 2) ==
             "https://hotels.example/hotels/lp1?checkin=2026-11-10&checkout=2026-11-13&adults=2"
  end

  test "the owner finds hotels for their dates on the Where to stay page", %{conn: conn} do
    Req.Test.stub(Hotels, &Req.Test.json(&1, @rates))

    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    poet = poet_fixture(user, %{current_place_name: "Kraków"})
    entry = published_entry_fixture(poet)

    %StayArea{}
    |> StayArea.changeset(%{
      poet_id: poet.id,
      journal_entry_id: entry.id,
      city: "Kraków",
      name: "Kazimierz",
      recommended: true,
      lat: 50.0513,
      lng: 19.9465
    })
    |> Repo.insert!()

    place_fixture(poet, entry, %{name: "Bakery", category: "cafe", lat: 50.0517, lng: 19.9470})

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, ~p"/journal/#{Date.to_iso8601(entry.entry_date)}?spread=stay")
    Req.Test.allow(Hotels, self(), view.pid)

    view
    |> form("#hotel-search-form", %{checkin: "2026-11-10", checkout: "2026-11-13", adults: "2"})
    |> render_submit()

    assert render_async(view) =~ "Courtyard Rooms"
    assert has_element?(view, "#hotel-near", "€80 a night")
    assert has_element?(view, "#hotel-near", "within a ten-minute walk, in Kazimierz")
  end
end
