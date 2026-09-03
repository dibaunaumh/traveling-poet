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
      refute poet.is_public

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

    test "the send-off form can rename the reader and make the journal public", %{conn: conn} do
      {user, view, _html} = mount(conn)

      render_click(view, "next", %{})
      render_click(view, "next", %{})

      view
      |> form("#onboarding-send-off", %{"name" => "Udi", "is_public" => "on"})
      |> render_change()

      view |> form("#onboarding-send-off", %{"name" => "Udi"}) |> render_submit()
      assert_redirect(view, ~p"/journal")

      assert Poets.get_poet_by_user(user.id).is_public
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
end
