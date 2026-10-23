defmodule TravelingPoetWeb.GoogleMapsSaveTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Bookmarks, GooglePlaces, MapsLinks, Repo}

  @app_ua "Mozilla/5.0 (iPhone) AppleWebKit/605.1.15 TravelingPoetiOS/1.0"

  defp signed_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  # Google's answer: an id made from the name searched for, nothing for a
  # name with "Nowhere" in it. Every search is reported to the test.
  defp stub_google(test \\ self()) do
    Req.Test.stub(GooglePlaces, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(body)
      send(test, {:search, body, Plug.Conn.get_req_header(conn, "x-goog-fieldmask")})
      name = body["textQuery"] |> String.split(",") |> hd()

      if name =~ "Nowhere",
        do: Req.Test.json(conn, %{}),
        else:
          Req.Test.json(conn, %{
            places: [
              %{
                id: "ChIJ-" <> String.replace(name, " ", ""),
                displayName: %{text: name},
                formattedAddress: "Kraków, Poland"
              }
            ]
          })
    end)
  end

  defp with_key(_) do
    Application.put_env(:traveling_poet, :google_maps_api_key, "test-key")
    on_exit(fn -> Application.delete_env(:traveling_poet, :google_maps_api_key) end)
    :ok
  end

  describe "MapsLinks.shortlist_urls/1" do
    test "twenty ids to a link" do
      ids = for n <- 1..45, do: "id#{n}"
      [first, second, third] = MapsLinks.shortlist_urls(ids)

      assert first ==
               "https://www.google.com/maps/@?api=1&map_action=shortlist&place_ids=" <>
                 Enum.join(Enum.map(1..20, &"id#{&1}"), ",")

      assert second =~ "place_ids=id21,"
      assert third =~ ~r/place_ids=id41,id42,id43,id44,id45$/
      assert MapsLinks.shortlist_urls([]) == []
    end
  end

  describe "GooglePlaces" do
    setup :with_key

    test "asks for the id only, held to a box around the place, and caches it" do
      stub_google()

      place = %{
        name: "Charlotte",
        address: "plac Szczepański 2, Kraków",
        lat: 50.0646,
        lng: 19.9358
      }

      assert GooglePlaces.resolve([place]) == %{GooglePlaces.key(place) => "ChIJ-Charlotte"}
      assert_received {:search, body, ["places.id,places.displayName,places.formattedAddress"]}
      assert body["textQuery"] == "Charlotte, plac Szczepański 2, Kraków"
      assert body["pageSize"] == 3
      %{"low" => low, "high" => high} = body["locationRestriction"]["rectangle"]
      assert low["latitude"] < 50.0646 and high["latitude"] > 50.0646
      assert low["longitude"] < 19.9358 and high["longitude"] > 19.9358
      # Under a km each way: a namesake branch across town stays out.
      assert high["latitude"] - low["latitude"] < 0.015
      assert high["longitude"] - low["longitude"] < 0.025

      # Known now: no second search, for this place or the same one spelt
      # with other spacing and case.
      assert GooglePlaces.resolve([%{place | name: "  charlotte "}]) |> map_size() == 1
      refute_received {:search, _, _}
    end

    test "a place Google does not find is left out and not asked again at once" do
      stub_google()
      place = %{name: "Nowhere Bar", address: nil, lat: 50.06, lng: 19.94}

      assert GooglePlaces.resolve([place]) == %{}
      assert_received {:search, %{"textQuery" => "Nowhere Bar"}, _}
      assert GooglePlaces.missing([place]) == []
      GooglePlaces.resolve([place])
      refute_received {:search, _, _}
    end

    test "Google's nearest guess for a place it does not know is not taken" do
      Req.Test.stub(GooglePlaces, fn conn ->
        Req.Test.json(conn, %{
          places: [
            %{
              id: "ChIJ-Starka",
              displayName: %{text: "Starka | Restaurant & Vodkas"},
              formattedAddress: "Józefa 14, 31-056 Kraków, Poland"
            },
            %{
              id: "ChIJ-Szara",
              displayName: %{text: "Szara Kazimierz"},
              formattedAddress: "Kraków"
            }
          ]
        })
      end)

      szara = %{
        name: "Szara Kazimierz",
        address: "Szeroka 39, 31-053 Kraków",
        lat: 50.0536,
        lng: 19.9468
      }

      # The right one, though Google ranked another first.
      assert GooglePlaces.resolve([szara]) == %{GooglePlaces.key(szara) => "ChIJ-Szara"}

      Req.Test.stub(GooglePlaces, fn conn ->
        Req.Test.json(conn, %{
          places: [
            %{
              id: "ChIJ-Starka",
              displayName: %{text: "Starka | Restaurant & Vodkas"},
              formattedAddress: "Józefa 14, 31-056 Kraków, Poland"
            }
          ]
        })
      end)

      closed = %{szara | name: "Szara Kazimierz Two", lat: 50.0537}
      assert GooglePlaces.resolve([closed]) == %{}
      assert GooglePlaces.missing([closed]) == []
    end

    test "a name the poet translated passes on its street and number" do
      basilica = %{name: "Bazylika Bożego Ciała", address: "Bożego Ciała 26, 31-059 Kraków"}

      assert GooglePlaces.same_place?(basilica, %{
               "displayName" => %{"text" => "Corpus Christi Basilica"},
               "formattedAddress" => "Bożego Ciała 26, 31-059 Kraków, Poland"
             })

      refute GooglePlaces.same_place?(%{name: "Lody", address: "Szeroka 3, Kraków"}, %{
               "displayName" => %{"text" => "Gelato"},
               "formattedAddress" => "Szeroka 39, Kraków, Poland"
             })

      refute GooglePlaces.same_place?(%{name: "The Bar", address: nil}, %{
               "displayName" => %{"text" => "Other Bar"},
               "formattedAddress" => "Kraków"
             })

      assert GooglePlaces.same_place?(%{name: "Café Camelot", address: nil}, %{
               "displayName" => %{"text" => "Camelot Cafe"}
             })
    end

    test "a failed search is not cached, and a place without coordinates is never searched" do
      Req.Test.stub(GooglePlaces, &Plug.Conn.send_resp(&1, 500, "oops"))
      place = %{name: "Charlotte", address: nil, lat: 50.06, lng: 19.94}

      assert GooglePlaces.resolve([place]) == %{}
      assert GooglePlaces.missing([place]) == [place]

      stub_google()

      assert GooglePlaces.resolve([%{name: "Pinless", address: "Kraków", lat: nil, lng: nil}]) ==
               %{}

      refute_received {:search, _, _}
    end
  end

  test "without a key nothing is looked up" do
    Req.Test.stub(GooglePlaces, fn _ -> flunk("searched without a key") end)
    refute GooglePlaces.enabled?()

    assert GooglePlaces.resolve([%{name: "Charlotte", address: nil, lat: 50.06, lng: 19.94}]) ==
             %{}
  end

  describe "in the guide" do
    setup :with_key

    setup do
      Req.Test.set_req_test_to_shared()
      stub_google()

      reader = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
      poet = poet_fixture(reader)
      entry = published_entry_fixture(poet)

      cafe =
        place_fixture(poet, entry, %{
          name: "Charlotte",
          category: "cafe",
          lat: 50.0646,
          lng: 19.9358
        })

      dinner =
        place_fixture(poet, entry, %{name: "Pod Baranami", lat: 50.0605, lng: 19.9355})

      lost = place_fixture(poet, entry, %{name: "Nowhere Bar", lat: 50.061, lng: 19.936})

      %{reader: reader, poet: poet, cafe: cafe, dinner: dinner, lost: lost}
    end

    test "the stay's places open in Google Maps as one list", %{conn: conn, reader: reader} do
      {:ok, view, _html} = live(signed_in(conn, reader), ~p"/guide")

      assert has_element?(view, "#guide-google-maps-pending")
      render_async(view)

      href =
        view
        |> element("#guide-google-maps-1")
        |> render()
        |> then(&Regex.run(~r/href="([^"]+)"/, &1))
        |> List.last()

      assert href =~ "https://www.google.com/maps/@?api=1&amp;map_action=shortlist&amp;place_ids="
      assert href =~ "ChIJ-Charlotte"
      assert href =~ "ChIJ-PodBaranami"
      refute has_element?(view, "#guide-google-maps-pending")

      assert view |> element("#guide-google-maps-left-out") |> render() =~
               "1 place Google could not find"
    end

    test "a filter narrows the list it saves", %{conn: conn, reader: reader} do
      {:ok, view, _html} = live(signed_in(conn, reader), ~p"/guide?filter=food")
      render_async(view)
      assert has_element?(view, "#guide-google-maps-1")

      {:ok, view, _html} = live(signed_in(conn, reader), ~p"/guide?filter=sights")
      render_async(view)
      refute has_element?(view, "#guide-google-maps-1")
    end

    test "a public guide offers it to any reader", %{conn: conn, poet: poet} do
      {:ok, poet} = poet |> Ecto.Changeset.change(is_public: true) |> Repo.update()
      {:ok, view, _html} = live(conn, ~p"/p/#{poet.slug}/guide")
      render_async(view)
      assert has_element?(view, ~s(#guide-google-maps-1[href*="ChIJ-Charlotte"]))
    end

    test "Saved and each planned day save to Google Maps, in the app too",
         %{conn: conn, reader: reader, cafe: cafe, dinner: dinner} do
      reader =
        reader
        |> Ecto.Changeset.change(ai_consent_at: DateTime.utc_now(:second))
        |> Repo.update!()

      {:ok, _} = Bookmarks.toggle(reader.id, "place", cafe.id)
      {:ok, _} = Bookmarks.toggle(reader.id, "place", dinner.id)

      conn = conn |> put_req_header("user-agent", @app_ua) |> signed_in(reader)
      {:ok, view, _html} = live(conn, ~p"/guide?saved=1")
      render_async(view)

      assert has_element?(view, ~s(#saved-google-maps-1[href*="ChIJ-Charlotte"]))
      assert has_element?(view, ~s(#saved-google-maps-1[href*="ChIJ-PodBaranami"]))
      assert has_element?(view, ~s(#plan-save-1-1[href*="map_action=shortlist"]))
      # The My Maps file is for a computer.
      refute has_element?(view, "#saved-to-maps")
    end

    test "known places show at once, with no search", %{
      conn: conn,
      reader: reader,
      cafe: cafe,
      dinner: dinner
    } do
      GooglePlaces.resolve([cafe, dinner])
      assert_received {:search, _, _}
      assert_received {:search, _, _}
      Application.delete_env(:traveling_poet, :google_maps_api_key)

      {:ok, view, _html} = live(signed_in(conn, reader), ~p"/guide")
      refute has_element?(view, "#guide-google-maps-pending")
      assert has_element?(view, ~s(#guide-google-maps-1[href*="ChIJ-PodBaranami"]))
      refute_received {:search, _, _}
    end
  end

  test "with no key and nothing cached there is no button", %{conn: conn} do
    reader = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    poet = poet_fixture(reader)
    entry = published_entry_fixture(poet)
    place_fixture(poet, entry, %{name: "Charlotte", lat: 50.0646, lng: 19.9358})

    {:ok, view, _html} = live(signed_in(conn, reader), ~p"/guide")
    refute has_element?(view, "#guide-google-maps")
  end
end
