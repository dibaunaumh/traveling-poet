defmodule TravelingPoetWeb.PageControllerTest do
  use TravelingPoetWeb.ConnCase

  import TravelingPoet.Fixtures

  test "GET / signed out shows the hero and sign-up CTAs", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    assert html =~ "Send someone ahead of you."
    assert html =~ "Send out your poet"
    # the destination box posts to /start, which parks the place across sign-in
    assert html =~ ~s(action="/start")
    assert html =~ ~s(name="place")
    assert html =~ "/images/hero-notebook.jpg"
    assert html =~ "first days of travel are on us"
    # no poets yet: the empty-state line, not a "0 poets" count
    assert html =~ "still lacing their boots"
    refute html =~ "0 poets exploring"
  end

  test "GET / map data carries avatar and a link to the latest published entry", %{conn: conn} do
    user = user_fixture()

    poet =
      poet_fixture(user, %{
        name: "Marta",
        is_public: true,
        status: "active",
        avatar_url: "/media/abc123"
      })

    {:ok, entry} =
      TravelingPoet.Journal.upsert_entry(poet.id, ~D[2026-08-20], %{title: "Older"})

    {:ok, _} = TravelingPoet.Journal.publish_entry(entry)

    {:ok, newest} =
      TravelingPoet.Journal.upsert_entry(poet.id, ~D[2026-08-27], %{title: "Newest"})

    {:ok, _} = TravelingPoet.Journal.publish_entry(newest)

    html = conn |> get(~p"/") |> html_response(200)
    assert html =~ "/media/abc123"
    assert html =~ "/p/#{poet.slug}/2026-08-27"
    assert html =~ "1 poet exploring the world"
  end

  test "GET / puts private poets on the map as anonymous pins", %{conn: conn} do
    poet_fixture(user_fixture(), %{name: "Marta", is_public: true, status: "active"})

    poet_fixture(user_fixture(), %{
      name: "Hidden Hilda",
      is_public: false,
      status: "active",
      current_lat: 13.7524938,
      current_lng: 100.4935089,
      current_place_name: "Bangkok, Thailand"
    })

    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "2 poets exploring the world"
    assert html =~ "journals are private"
    # the pin is there, blurred to ~10km, but nothing identifying it is
    refute html =~ "Hidden Hilda"
    refute html =~ "Bangkok"
    refute html =~ "hidden-hilda"
    refute html =~ "13.7524938"
    assert html =~ "13.8"
  end

  test "GET / omits poets who are not on the road", %{conn: conn} do
    poet_fixture(user_fixture(), %{name: "Marta", is_public: true, status: "active"})
    poet_fixture(user_fixture(), %{name: "Paused Pia", is_public: false, status: "paused"})

    poet_fixture(user_fixture(), %{
      name: "Nowhere Ned",
      is_public: false,
      status: "active",
      current_lat: nil,
      current_lng: nil
    })

    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "1 poet exploring the world"
    refute html =~ "journals are private"
  end

  test "GET / signed in hides sign-up CTAs and links to the journal", %{conn: conn} do
    user = user_fixture()
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    html = conn |> get(~p"/") |> html_response(200)
    # no poet yet: the box still leads into onboarding
    assert html =~ ~s(action="/start")
    refute html =~ "Open your journal"

    poet_fixture(user)
    html = conn |> get(~p"/") |> html_response(200)
    assert html =~ "Open your journal"
    refute html =~ ~s(action="/start")
    refute html =~ "Send out your poet"
    refute html =~ "Scout a trip"
    refute html =~ "/auth/google"
  end

  describe "the open notebook under the map" do
    defp publish(poet, date, title, sections) do
      {:ok, entry} =
        TravelingPoet.Journal.upsert_entry(poet.id, date, %{
          title: title,
          place_name: "Ronda, Spain"
        })

      {:ok, _} = TravelingPoet.Journal.replace_sections(entry, sections)
      {:ok, _} = TravelingPoet.Journal.publish_entry(entry)
      entry
    end

    test "shows the first poet's latest page, words left and drawing right, others hidden", %{
      conn: conn
    } do
      nam = poet_fixture(user_fixture(), %{name: "Nam", is_public: true, status: "active"})
      media = media_fixture(nam, %{alt_text: "Puente Nuevo in wash"})

      publish(nam, ~D[2026-09-03], "The town on the edge", [
        %{
          kind: "description",
          title: "First light",
          body: "I left Seville this morning on a bus."
        },
        %{kind: "illustration", title: "Sketch", body: "", media_id: media.id},
        %{kind: "poem", title: "Gorge", body: "The river carved a question mark"},
        %{kind: "products", title: "Worth carrying home", body: "Olive oil from the almazaras."}
      ])

      hilma = poet_fixture(user_fixture(), %{name: "Hilma", is_public: true, status: "active"})
      publish(hilma, ~D[2026-09-03], "Layers", [%{kind: "description", body: "Tokyo, at last."}])

      # a public poet with nothing published gets a pin but no page
      poet_fixture(user_fixture(), %{name: "Quiet Q", is_public: true, status: "active"})

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s(data-spread="landing-spread")
      assert html =~ "pick one and read this morning"
      assert html =~ "The town on the edge"
      assert html =~ "I left Seville this morning"
      assert html =~ "The river carved a question mark"
      assert html =~ "Olive oil from the almazaras"
      assert html =~ "/media/#{media.id}"
      assert html =~ "Puente Nuevo in wash"
      assert html =~ "Read the whole page"
      assert html =~ "Show on the map"
      assert html =~ "/p/#{nam.slug}/2026-09-03"

      # one article per poet with a page; the first is open, the rest closed
      assert html =~ ~s(data-spread-poet="#{nam.slug}")
      assert html =~ ~s(data-spread-poet="#{hilma.slug}" hidden)
      refute html =~ ~s(data-spread-poet="#{nam.slug}" hidden)
      refute html =~ ~s(data-spread-poet="quiet-q")

      # the picker names both poets, marks the first
      assert html =~ ~s(data-spread-pick="#{nam.slug}" aria-selected="true")
      assert html =~ ~s(data-spread-pick="#{hilma.slug}" aria-selected="false")
    end

    test "no published pages means a map without a spread", %{conn: conn} do
      poet_fixture(user_fixture(), %{name: "Marta", is_public: true, status: "active"})
      html = conn |> get(~p"/") |> html_response(200)
      refute html =~ ~s(id="landing-spread")
      refute html =~ ~s(data-spread=)
    end
  end

  describe "GET /start (the hero's destination box)" do
    test "signed out: parks the place in the session and goes to Google sign-in", %{conn: conn} do
      conn = get(conn, ~p"/start", place: "  Lisbon ")
      assert redirected_to(conn) == "/auth/google"
      assert get_session(conn, :start_place) == "Lisbon"
    end

    test "signed out with nothing typed: plain sign-in, nothing parked", %{conn: conn} do
      conn = get(conn, ~p"/start", place: "")
      assert redirected_to(conn) == "/auth/google"
      assert get_session(conn, :start_place) == nil
    end

    test "signed in without a poet: straight to onboarding with the place", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> Plug.Test.init_test_session(%{user_id: user.id})
        |> get(~p"/start", place: "Kyoto")

      assert redirected_to(conn) == "/onboarding?place=Kyoto"
    end

    test "signed in with a poet on the road: the journal", %{conn: conn} do
      user = user_fixture(%{onboarding_completed: true})
      poet_fixture(user)

      conn =
        conn
        |> Plug.Test.init_test_session(%{user_id: user.id})
        |> get(~p"/start", place: "Kyoto")

      assert redirected_to(conn) == "/journal"
    end
  end
end
