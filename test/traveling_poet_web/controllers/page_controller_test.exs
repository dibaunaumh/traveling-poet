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
    # the "on us" line lives with the closing call to action, not in the hero
    assert html =~ "first days of travel are on us"
    [above_the_map | _] = String.split(html, "Poets on the road right now")
    refute above_the_map =~ "first days of travel"
    assert html =~ "Two ways to travel. Both end up in the same notebook."
    assert html =~ "Somewhere in the world, a page is being written for you."
    assert html =~ "Trips scouted, not sold."
    assert html =~ "Why this isn&rsquo;t another travel app."
    # no poets yet: the empty-state line, not a "0 poets" count
    assert html =~ "still lacing their boots"
    refute html =~ "0 poets exploring"
  end

  # "Poets on the road" is a compact Discover (DiscoverLive, embedded): the
  # same data, overviews and privacy rule as /discover.
  test "GET / shows the fleet through the embedded Discover", %{conn: conn} do
    marta =
      poet_fixture(user_fixture(), %{
        name: "Marta",
        is_public: true,
        status: "active",
        avatar_url: "/media/abc123"
      })

    published_entry_fixture(marta, %{
      entry_date: ~D[2026-08-20],
      title: "Older",
      lat: 1.0,
      lng: 1.0
    })

    newest =
      published_entry_fixture(marta, %{
        entry_date: ~D[2026-08-27],
        title: "Newest",
        teaser: "Salt on the wind.",
        lat: 1.0,
        lng: 1.0
      })

    poet_fixture(user_fixture(), %{
      name: "Hidden Hilda",
      is_public: false,
      status: "active",
      current_lat: 13.7524938,
      current_lng: 100.4935089,
      current_place_name: "Bangkok, Thailand"
    })

    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "Poets on the road right now"
    assert html =~ ~s(id="discover-compact")
    assert html =~ ~s(phx-hook="DiscoverMap")
    # the newest page is open beside the map, with the way in
    assert html =~ ~s(id="discover-entry-#{newest.id}")
    assert html =~ "Salt on the wind."
    assert html =~ "/p/#{marta.slug}/2026-08-27"
    assert html =~ "/media/abc123"
    assert html =~ ~s(href="/discover")
    assert html =~ "2 poets on the road"

    # the private poet is a blurred dot, nothing identifying
    assert html =~ "journals are private"
    refute html =~ "Hidden Hilda"
    refute html =~ "Bangkok"
    refute html =~ "13.7524938"
    assert html =~ "13.8"
  end

  test "GET / with nobody on the road says so, without a count", %{conn: conn} do
    poet_fixture(user_fixture(), %{name: "Paused Pia", is_public: true, status: "paused"})

    html = conn |> get(~p"/") |> html_response(200)
    assert html =~ "still lacing their boots"
    refute html =~ "on the road,"
  end

  test "GET / signed in hides sign-up CTAs and links to the journal", %{conn: conn} do
    user = user_fixture()
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    html = conn |> get(~p"/") |> html_response(200)
    # no poet yet: the box still leads into onboarding
    # no poet yet: the box and the mode buttons still lead into onboarding
    assert html =~ ~s(action="/start")
    assert html =~ "Scout a trip"
    assert html =~ "connect your Google Calendar"
    assert html =~ "a day off the road"
    refute html =~ "Open your journal"
    refute html =~ "/auth/google"

    poet_fixture(user)
    html = conn |> get(~p"/") |> html_response(200)
    assert html =~ "Open your journal"
    refute html =~ ~s(action="/start")
    refute html =~ "Send out your poet"
    refute html =~ "Scout a trip"
    refute html =~ "first days of travel are on us"
    refute html =~ "/auth/google"
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

  describe "the documents Google's consent screen points at" do
    test "GET /privacy says what is stored, who sees it, and how to have it deleted",
         %{conn: conn} do
      html = conn |> get(~p"/privacy") |> html_response(200)

      assert html =~ "Privacy Policy"
      assert html =~ "Last updated"
      # the providers that actually see something
      for third_party <- ["Google", "Fly.io", "Tigris", "sprites.dev", "OpenRouter", "Stripe"] do
        assert html =~ third_party
      end

      # Google's verification looks for the Limited Use wording and the scope
      assert html =~ "Google API Services User Data Policy"
      assert html =~ "Limited Use"
      assert html =~ "drive.file"

      assert html =~ "dibaunaumh@gmail.com"
      assert html =~ "deleted"
      assert html =~ ~s(href="/terms")
    end

    test "GET /terms covers the service, credits, fair use and liability", %{conn: conn} do
      html = conn |> get(~p"/terms") |> html_response(200)

      assert html =~ "Terms of Service"
      assert html =~ "not as travel advice"
      assert html =~ "Credits"
      assert html =~ "16 or older"
      assert html =~ "without warranties"
      assert html =~ "dibaunaumh@gmail.com"
      assert html =~ ~s(href="/privacy")
    end

    test "both are reachable signed out, and linked from the home page", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)
      assert html =~ ~s(href="/privacy")
      assert html =~ ~s(href="/terms")
    end
  end
end
