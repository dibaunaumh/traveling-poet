defmodule TravelingPoetWeb.OnboardingLiveTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, Poets}
  alias TravelingPoet.Poets.Presets

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  defp mount(conn) do
    user = user_fixture()
    {:ok, view, html} = live(sign_in(conn, user), ~p"/onboarding")
    {user, view, html}
  end

  # A typed name that is not in the presets, so the assertions can't pass by
  # luck of the draw.
  @typed_name "Zebedee Quince"

  describe "the default path" do
    test "arrives pre-filled: a poet name, a personality, a starting city", %{conn: conn} do
      {_user, _view, html} = mount(conn)

      assert html =~ "Step 1 of 3"
      assert html =~ "Meet your poet"

      assert Enum.any?(Presets.names(), fn name ->
               html =~ ~s(name="poet_name" value="#{name}")
             end)

      # One personality preset is active and previewed
      assert html =~ ~r/id="personality-chip-\d+"[^>]*btn-primary/s
      assert html =~ ~s(id="personality-preview")
    end

    test "three clicks create the poet without typing anything", %{conn: conn} do
      {user, view, _html} = mount(conn)

      html = render_click(view, "next", %{})
      assert html =~ "Step 2 of 3"
      assert html =~ "Setting out from"
      refute html =~ ~s(id="journey-continue"[^>]*disabled)

      html = render_click(view, "next", %{})
      assert html =~ "Step 3 of 3"
      assert html =~ "Ready to set out"
      assert html =~ "Wanderer"

      render_click(view, "create_poet", %{})
      assert_redirect(view, ~p"/journal")

      poet = Poets.get_poet_by_user(user.id)
      assert poet
      assert String.trim(poet.name) != ""
      assert poet.name in Presets.names()
      assert String.trim(poet.personality) != ""
      assert poet.current_place_name
      assert poet.current_lat
      assert poet.settings["mode"] == "wander"
      assert poet.settings["verbosity"] == "balanced"
      assert length(poet.currently_reading["items"]) == 1
      assert poet.is_public

      user = Accounts.get_user!(user.id)
      assert user.onboarding_completed
      assert user.onboarding_step == "done"
      # Provisioning is disabled in test config; nothing should have been touched.
      refute user.sprite_provisioned
      assert user.name =~ "Test User"
    end

    test "the pre-picked defaults are the same on the static and connected render", %{
      conn: conn
    } do
      user = user_fixture()
      conn = sign_in(conn, user)

      static = conn |> get(~p"/onboarding") |> html_response(200)
      {:ok, _view, connected} = live(conn, ~p"/onboarding")

      [name] = Regex.run(~r/name="poet_name" value="([^"]+)"/, static, capture: :all_but_first)
      assert connected =~ ~s(name="poet_name" value="#{name}")
    end
  end

  # card-61: a reader found their poet too lyrical. Each voice shows a sample of
  # the same scene, and there is a plain, factual one to pick.
  describe "choosing a voice" do
    test "every preset carries a sample, in interface copy rules" do
      for p <- Presets.personalities() do
        assert is_binary(p["sample"]) and String.length(p["sample"]) > 100, p["label"]
        refute p["sample"] =~ ~r/[\x{2014}\x{2013}]/u, "dash in #{p["label"]}"
      end

      assert Enum.any?(Presets.personalities(), &(&1["label"] == "Documentary narrator"))
    end

    test "the sample follows the chip you pick, and goes away for your own words",
         %{conn: conn} do
      {_user, view, html} = mount(conn)
      assert html =~ ~s(id="personality-sample")

      idx = Enum.find_index(Presets.personalities(), &(&1["label"] == "Documentary narrator"))
      html = render_click(view, "pick_personality", %{"idx" => to_string(idx)})
      assert html =~ "The market opens at five."

      html = render_click(view, "custom_personality", %{})
      refute html =~ ~s(id="personality-sample")
    end
  end

  describe "editing the defaults" do
    test "shuffle picks a different preset name", %{conn: conn} do
      {_user, view, html} = mount(conn)
      [before] = Regex.run(~r/name="poet_name" value="([^"]+)"/, html, capture: :all_but_first)

      html = render_click(view, "shuffle_name", %{})
      [after_] = Regex.run(~r/name="poet_name" value="([^"]+)"/, html, capture: :all_but_first)

      assert after_ != before
      assert after_ in Presets.names()
    end

    test "a typed name and custom personality survive chip clicks and stepping back", %{
      conn: conn
    } do
      {_user, view, _html} = mount(conn)

      render_click(view, "custom_personality", %{})

      view
      |> form("#onboarding-poet", %{
        "poet_name" => @typed_name,
        "personality_custom" => "obsessed with bridges"
      })
      |> render_change()

      # Opening "More options" and picking a book used to wipe typed input.
      render_click(view, "toggle_more", %{})
      html = render_click(view, "toggle_reading", %{"idx" => "2"})
      assert html =~ @typed_name
      assert html =~ "obsessed with bridges"

      render_click(view, "next", %{})
      html = render_click(view, "back", %{})
      assert html =~ @typed_name
      assert html =~ "obsessed with bridges"
    end

    test "chattiness picked under More options is kept", %{conn: conn} do
      {_user, view, _html} = mount(conn)

      render_click(view, "toggle_more", %{})

      view
      |> form("#onboarding-poet", %{"verbosity" => "expansive"})
      |> render_change()

      html = render_click(view, "toggle_reading", %{"idx" => "0"})

      assert html =~ ~r/value="expansive"[^>]*checked/s or
               html =~ ~r/checked[^>]*value="expansive"/s
    end

    test "a blank poet name cannot continue", %{conn: conn} do
      {_user, view, _html} = mount(conn)

      html =
        view
        |> form("#onboarding-poet", %{"poet_name" => "   "})
        |> render_submit()

      assert html =~ "Step 1 of 3"
      assert html =~ "needs a name"
    end

    test "passions picked at onboarding become active tastes that steer every day",
         %{conn: conn} do
      {user, view, _html} = mount(conn)
      render_click(view, "next", %{})

      for domain <- ~w(food photography mountains art) do
        render_click(view, "toggle_passion", %{"domain" => domain})
      end

      # three at most: the fourth tile is disabled and its click ignored
      html = render(view)
      assert html =~ ~r/id="passion-art"[^>]*disabled/s

      view
      |> form("#onboarding-passions", %{
        "passion_words" => %{"food" => "street food, natural wine", "mountains" => ""}
      })
      |> render_change()

      render_click(view, "next", %{})
      render_click(view, "create_poet", %{})

      poet = Poets.get_poet_by_user(user.id)

      assert [
               %{domain: "food", taste: "street food, natural wine"},
               %{domain: "photography", taste: "Photography"},
               %{domain: "mountains", taste: "Mountains & climbing"}
             ] = TravelingPoet.Topics.focus(poet.id)

      assert Enum.all?(TravelingPoet.Topics.list(poet.id), &(&1.source == "onboarding"))
      assert "Food & drink: street food, natural wine" in poet.settings["user_interests"]
    end

    test "interest chips and free text both reach the poet", %{conn: conn} do
      {user, view, _html} = mount(conn)

      render_click(view, "next", %{})
      render_click(view, "toggle_interest", %{"label" => "trains"})

      view
      |> form("#onboarding-interests", %{"custom_interests" => "hidden gardens, jazz"})
      |> render_change()

      render_click(view, "next", %{})
      render_click(view, "create_poet", %{})

      poet = Poets.get_poet_by_user(user.id)
      assert poet.interests == ["trains", "hidden gardens", "jazz"]
      assert poet.settings["user_interests"] == ["trains", "hidden gardens", "jazz"]
    end

    test "the send-off form can rename the reader and keep the journal private", %{conn: conn} do
      {user, view, _html} = mount(conn)

      render_click(view, "next", %{})
      html = render_click(view, "next", %{})
      assert html =~ ~r/name="is_public"[^>]*checked/

      # An unchecked checkbox is absent from the params while the form still
      # carries "name". The form helper would fill the checked box back in, so
      # send the change the way the browser does.
      render_change(view, "capture", %{"name" => "Udi"})

      view |> form("#onboarding-send-off", %{"name" => "Udi"}) |> render_submit()
      assert_redirect(view, ~p"/journal")

      refute Poets.get_poet_by_user(user.id).is_public
      assert Accounts.get_user!(user.id).name == "Udi"
    end

    test "a cleared reader name keeps the sign-in name", %{conn: conn} do
      {user, view, _html} = mount(conn)

      render_click(view, "next", %{})
      render_click(view, "next", %{})
      view |> form("#onboarding-send-off", %{"name" => "  "}) |> render_submit()

      assert Accounts.get_user!(user.id).name == user.name
    end
  end

  describe "trip scout" do
    test "needs at least one stop before continuing", %{conn: conn} do
      {_user, view, _html} = mount(conn)

      render_click(view, "next", %{})
      html = render_click(view, "choose_mode", %{"mode" => "scout"})

      assert html =~ "Where are you planning to go?" or html =~ "Add the places"
      assert html =~ ~r/id="journey-continue"[^>]*disabled/s

      # Switching back to Wanderer restores the ready-to-go default
      html = render_click(view, "choose_mode", %{"mode" => "wander"})
      refute html =~ ~r/id="journey-continue"[^>]*disabled/s
    end
  end

  describe "funnel tracking" do
    test "records the step the user is on", %{conn: conn} do
      {user, view, _html} = mount(conn)
      assert Accounts.get_user!(user.id).onboarding_step == "poet"

      render_click(view, "next", %{})
      assert Accounts.get_user!(user.id).onboarding_step == "journey"

      render_click(view, "next", %{})
      assert Accounts.get_user!(user.id).onboarding_step == "send_off"

      render_click(view, "back", %{})
      assert Accounts.get_user!(user.id).onboarding_step == "journey"
    end
  end

  describe "?place= from the home page" do
    # Geocoding is off in test, so every lookup comes back empty: the wizard
    # must keep the visitor's words and hand them the search box.
    test "an unknown place keeps what was typed and opens the search", %{conn: conn} do
      user = user_fixture()
      {:ok, view, _html} = live(sign_in(conn, user), ~p"/onboarding?place=Atlantis")

      # the starting city lives on step 2
      html = view |> element("#onboarding-poet") |> render_submit()
      assert html =~ "Couldn’t find “Atlantis”"
      assert html =~ ~s(name="query" value="Atlantis")
      # the default city is still there to fall back on
      assert html =~ ~r/Setting out from <b[^>]*>/
    end

    test "no place means the ordinary pre-filled start", %{conn: conn} do
      user = user_fixture()
      {:ok, view, _html} = live(sign_in(conn, user), ~p"/onboarding?place=")
      html = view |> element("#onboarding-poet") |> render_submit()
      assert html =~ ~r/Setting out from <b[^>]*>/
      refute html =~ "Couldn’t find"
    end
  end

  # The home page's box suggests "Lisbon, Kyoto, Oaxaca…", so people type a
  # list (card-97). Nominatim answers a list with noise, so the wizard reads
  # it itself: a city after the comma is a route, a country or state is a
  # qualifier. The geocoder is faked here, query by query.
  describe "a list of places" do
    defp hit(name, kind, city),
      do: %{place_name: name, kind: kind, city: city, lat: 1.0, lng: 2.0, country_code: "PT"}

    setup do
      answers = %{
        "Lisbon" => [hit("Lisboa, Portugal", "city", "Lisboa")],
        "Porto" => [hit("Porto, Portugal", "city", "Porto")],
        "Texas" => [hit("Texas, United States", "state", nil)],
        "Thailand" => [hit("Thailand", "country", nil)],
        "Paris, Texas" => [hit("Paris, Lamar County, Texas, United States", "city", "Paris")]
      }

      Application.put_env(:traveling_poet, :destination_search, fn q ->
        {:ok, Map.get(answers, q, [])}
      end)

      on_exit(fn -> Application.delete_env(:traveling_poet, :destination_search) end)
      :ok
    end

    test "from the home page, a route makes a Trip Scout with the stops in order", %{conn: conn} do
      user = user_fixture()
      {:ok, view, _html} = live(sign_in(conn, user), ~p"/onboarding?place=Lisbon,+Porto")
      render_async(view)

      html = view |> element("#onboarding-poet") |> render_submit()
      assert html =~ ~r/id="mode-scout"[^>]*class="[^"]*border-primary/s
      assert html =~ "scout them in this order: Lisboa, Porto"
      assert html =~ ~r/1\.<\/span>\s*<span class="flex-1">Lisboa, Portugal/
      assert html =~ ~r/2\.<\/span>\s*<span class="flex-1">Porto, Portugal/
      refute html =~ "Couldn’t find"
      refute html =~ ~r/id="journey-continue"[^>]*disabled/s
    end

    # 2026-10-19: "Thailand" put a poet on the country's centre point, and
    # three pages said "Written from Thailand".
    test "a country is a region the poet picks its town in", %{conn: conn} do
      user = user_fixture()
      {:ok, view, _html} = live(sign_in(conn, user), ~p"/onboarding?place=Thailand")
      render_async(view)

      html = view |> element("#onboarding-poet") |> render_submit()
      assert html =~ ~r/Setting out from <b[^>]*>Thailand/
      assert html =~ "Your poet will choose a town there to start from."

      render_click(view, "next", %{})
      render_click(view, "create_poet", %{})
      poet = Poets.get_poet_by_user(user.id)
      assert Poets.start_region(poet) == "Thailand"
    end

    test "a city is not a region", %{conn: conn} do
      user = user_fixture()
      {:ok, view, _html} = live(sign_in(conn, user), ~p"/onboarding?place=Porto")
      render_async(view)

      html = view |> element("#onboarding-poet") |> render_submit()
      refute html =~ "region-start-note"
      render_click(view, "next", %{})
      render_click(view, "create_poet", %{})
      assert Poets.start_region(Poets.get_poet_by_user(user.id)) == nil
    end

    test "a place qualified by its state stays one place", %{conn: conn} do
      user = user_fixture()
      {:ok, view, _html} = live(sign_in(conn, user), ~p"/onboarding?place=Paris,+Texas")
      render_async(view)

      html = view |> element("#onboarding-poet") |> render_submit()
      assert html =~ ~r/Setting out from <b[^>]*>Paris, Lamar County, Texas/
      refute html =~ "scout them in this order"
    end

    test "in the wizard's own box, a route turns a wanderer into a scout and names what it could not find",
         %{conn: conn} do
      {_user, view, _html} = mount(conn)
      render_click(view, "next", %{})
      render_click(view, "toggle_location_search", %{})

      html = render_submit(view, "search_location", %{"query" => "Lisbon, Atlantis, Porto"})
      assert html =~ "Looking up “Lisbon, Atlantis, Porto”…"
      html = render_async(view)

      assert html =~ "scout them in this order: Lisboa, Porto"
      assert html =~ "Couldn’t find “Atlantis” — search below to add it."
      assert html =~ ~r/2\.<\/span>\s*<span class="flex-1">Porto, Portugal/

      # The scout's box still lists one place for a tap, and a list appends.
      render_submit(view, "search_location", %{"query" => "Lisbon"})
      html = render_async(view)
      assert html =~ "+ Lisboa, Portugal"
      refute html =~ "Couldn’t find"
      html = render_click(view, "add_stop", %{"idx" => "0"})
      assert html =~ ~r/3\.<\/span>\s*<span class="flex-1">Lisboa, Portugal/

      render_submit(view, "search_location", %{"query" => "Porto, Lisbon"})
      html = render_async(view)
      assert html =~ ~r/5\.<\/span>\s*<span class="flex-1">Lisboa, Portugal/

      # Back to Wanderer with one tap; the notice goes with it.
      html = render_click(view, "choose_mode", %{"mode" => "wander"})
      refute html =~ "scout them in this order"
    end

    test "one place in the wizard's box is picked for a wanderer as before", %{conn: conn} do
      {_user, view, _html} = mount(conn)
      render_click(view, "next", %{})
      render_click(view, "toggle_location_search", %{})
      render_submit(view, "search_location", %{"query" => "Porto"})
      html = render_async(view)
      assert html =~ ~r/Setting out from <b[^>]*>Porto, Portugal/
      refute html =~ "scout them in this order"
    end
  end
end
