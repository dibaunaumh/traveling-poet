defmodule TravelingPoetWeb.NearHomeLiveTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, NearHome, WebPush}
  alias TravelingPoet.Telegram.Notifier

  # Reports the call and answers at once.
  defmodule FakeSession do
    def run(user, note, _opts) do
      if pid = Process.whereis(:near_home_live_test), do: send(pid, {:session_run, user.id, note})
      {:ok, "Nothing much on this week."}
    end
  end

  setup do
    Process.register(self(), :near_home_live_test)
    Application.put_env(:traveling_poet, :sprites_client, TravelingPoet.SpritesClientRecorder)
    Application.put_env(:traveling_poet, :agent_session, FakeSession)

    on_exit(fn ->
      Application.delete_env(:traveling_poet, :sprites_client)
      Application.delete_env(:traveling_poet, :agent_session)
    end)

    user =
      agent_user_fixture(%{
        onboarding_completed: true,
        credits: 10,
        home_place_name: "Lisbon, Portugal",
        home_lat: 38.7223,
        home_lng: -9.1393
      })

    poet = poet_fixture(user, %{name: "Wren"})
    %{user: user, poet: poet}
  end

  defp signed_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  defp today, do: Date.utc_today()

  defp seed(user, poet, date \\ nil, picks \\ nil) do
    picks =
      picks ||
        [
          %{
            name: "Feira da Ladra",
            kind: "market",
            starts_on: Date.add(today(), 2),
            ends_on: Date.add(today(), 2),
            place_name: "Campo de Santa Clara",
            address: "Campo de Santa Clara, Lisbon",
            lat: 38.7148,
            lng: -9.1263,
            distance_km: 1.4,
            url: "https://example.com/feira",
            blurb: "Old prints and tiles, early on Saturday.",
            position: 0
          },
          %{
            name: "Tiles of the Ribeira",
            kind: "exhibition",
            starts_on: Date.add(today(), -20),
            ends_on: Date.add(today(), 30),
            place_name: "Museu do Azulejo",
            lat: 38.7247,
            lng: -9.1136,
            distance_km: 2.6,
            url: "https://example.com/tiles",
            position: 1
          }
        ]

    NearHome.replace_batch(user, poet, date || today(), picks)
  end

  describe "this_week/2" do
    test "drops what is over, and the whole batch once it is a week old", %{
      user: user,
      poet: poet
    } do
      seed(user, poet, today(), [
        %{name: "Still on", url: "https://example.com/a", ends_on: Date.add(today(), 1)},
        %{name: "Over", url: "https://example.com/b", ends_on: Date.add(today(), -1)},
        %{name: "Open all week", url: "https://example.com/c", when_text: "Daily 10-18"}
      ])

      assert Enum.map(NearHome.this_week(user.id), & &1.name) == ["Still on", "Open all week"]
      assert NearHome.this_week(user.id, Date.add(today(), 6)) != []
      assert NearHome.this_week(user.id, Date.add(today(), 7)) == []
    end
  end

  describe "/guide/near" do
    test "lists the week's picks with when, where, how far, and pins", %{
      conn: conn,
      user: user,
      poet: poet
    } do
      seed(user, poet)
      {:ok, _view, html} = live(signed_in(conn, user), ~p"/guide/near")

      assert html =~ "Feira da Ladra"
      assert html =~ "Campo de Santa Clara, Lisbon"
      # the address already names the venue: said once
      refute html =~ "Campo de Santa Clara, Campo de Santa Clara"
      assert html =~ "Museu do Azulejo"
      assert html =~ "1.4 km from home"
      assert html =~ "Old prints and tiles"
      # running already: says until when, not when it began
      assert html =~ "Until"
      assert html =~ ~s(href="https://example.com/feira")
      assert html =~ ~s(id="guide-journey-near")

      [_, pins] = Regex.run(~r/data-places="([^"]+)"/, html)
      assert pins =~ "Feira da Ladra"
      assert pins =~ "Tiles of the Ribeira"
    end

    test "without a home it asks for one; the guide shows no Near you tab", %{conn: conn} do
      reader = agent_user_fixture(%{onboarding_completed: true})
      poet_fixture(reader)

      {:ok, _view, html} = live(signed_in(conn, reader), ~p"/guide/near")
      assert html =~ ~s(id="near-no-home")

      {:ok, _view, html} = live(signed_in(conn, reader), ~p"/guide")
      refute html =~ ~s(id="guide-journey-near")
    end

    test "with a home the guide links to it", %{conn: conn, user: user, poet: poet} do
      published_entry_fixture(poet)
      {:ok, view, _html} = live(signed_in(conn, user), ~p"/guide")
      assert has_element?(view, "#guide-journey-near[href='/guide/near']")
    end

    test "switched off, it says so and lists nothing", %{conn: conn, user: user, poet: poet} do
      seed(user, poet)
      {:ok, _} = NearHome.set_enabled(user, false)

      {:ok, _view, html} = live(signed_in(conn, user), ~p"/guide/near")
      assert html =~ ~s(id="near-off")
      refute html =~ "Feira da Ladra"
    end

    test "Look now asks the poet, once a day", %{conn: conn, user: user} do
      {:ok, view, html} = live(signed_in(conn, user), ~p"/guide/near")
      assert html =~ ~s(id="near-empty")

      html = view |> element("#near-look-now") |> render_click()
      # the wait is minutes, and says so
      assert html =~ "This takes about ten minutes"
      assert_receive {:session_run, _, note}
      assert note =~ "Lisbon, Portugal"
      # FakeSession answered without sending picks
      assert render(view) =~ "found nothing that fits this week"

      html = view |> element("#near-look-now") |> render_click()
      assert html =~ "already looked near you today"
    end

    test "a page opened mid-search shows the wait, not another button", %{
      conn: conn,
      user: user,
      poet: poet
    } do
      {:ok, _} = TravelingPoet.Usage.record(user.id, NearHome.usage_kind())
      {:ok, view, html} = live(signed_in(conn, user), ~p"/guide/near")
      assert html =~ "This takes about ten minutes"
      assert has_element?(view, "#near-look-now[disabled]")

      seed(user, poet)
      refute NearHome.looking?(user.id)
    end

    test "picks landing while the page is open show up", %{conn: conn, user: user, poet: poet} do
      {:ok, view, _html} = live(signed_in(conn, user), ~p"/guide/near")
      seed(user, poet)
      send(view.pid, {:near_home, today()})
      assert render(view) =~ "Feira da Ladra"
    end
  end

  describe "journal and settings" do
    test "the journal shows the week's card with a way to the list", %{
      conn: conn,
      user: user,
      poet: poet
    } do
      published_entry_fixture(poet)
      {:ok, view, html} = live(signed_in(conn, user), ~p"/journal")
      refute html =~ ~s(id="near-home-card")

      seed(user, poet)
      send(view.pid, {:near_home, today()})
      html = render(view)
      assert html =~ ~s(id="near-home-card")
      assert html =~ "Wren found 2 things near you this week"
      assert has_element?(view, "#near-home-card-open[href='/guide/near']")
    end

    test "closing the card hides it until the next week's picks", %{
      conn: conn,
      user: user,
      poet: poet
    } do
      published_entry_fixture(poet)
      seed(user, poet, Date.add(today(), -6))

      {:ok, view, _html} = live(signed_in(conn, user), ~p"/journal")
      html = view |> element("#near-home-card-hide") |> render_click()
      refute html =~ ~s(id="near-home-card")

      {:ok, view, html} = live(signed_in(conn, user), ~p"/journal")
      refute html =~ ~s(id="near-home-card")

      seed(user, poet)
      send(view.pid, {:near_home, today()})
      assert render(view) =~ ~s(id="near-home-card")
    end

    test "Home stays in Settings when the calendar's Trips card is hidden", %{
      conn: conn,
      user: user
    } do
      Application.put_env(:traveling_poet, :calendar_enabled, "admins")
      on_exit(fn -> Application.put_env(:traveling_poet, :calendar_enabled, "all") end)

      {:ok, _view, html} = live(signed_in(conn, user), ~p"/settings")
      refute html =~ ~s(id="trip-settings")
      assert html =~ ~s(id="home")
      assert html =~ "Lisbon, Portugal"
      assert html =~ ~s(id="near-home-toggle")
    end

    test "Settings switches it off and on, beside the home city", %{conn: conn, user: user} do
      {:ok, view, html} = live(signed_in(conn, user), ~p"/settings")
      assert html =~ ~s(id="near-home-setting")

      view |> element("#near-home-toggle") |> render_click()
      refute Accounts.get_user!(user.id).near_home

      view |> element("#near-home-toggle") |> render_click()
      assert Accounts.get_user!(user.id).near_home
    end
  end

  describe "notifications" do
    test "the reader hears once a day, not on every resend", %{user: user, poet: poet} do
      Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "near_home")

      Req.Test.stub(TravelingPoet.LinkCheck, fn conn -> Req.Test.text(conn, "ok") end)

      pick = %{
        "name" => "Feira da Ladra",
        "url" => "https://example.com/feira",
        "starts_on" => Date.to_iso8601(Date.add(today(), 2)),
        "lat" => 38.7148,
        "lng" => -9.1263
      }

      {:ok, %{kept: [_]}} = NearHome.ingest(user, poet, [pick], today())
      user_id = user.id
      assert_receive {:near_home_ready, ^user_id, _}

      {:ok, %{kept: [_, _]}} =
        NearHome.ingest(user, poet, [pick, Map.put(pick, "name", "Another")], today())

      refute_receive {:near_home_ready, _, _}
    end

    test "push and Telegram name the picks and lead to the list", %{user: user, poet: poet} do
      picks = seed(user, poet)

      payload = WebPush.near_home_payload(poet, picks)
      assert payload.title == "Wren found 2 things near you this week"
      assert payload.body == "Feira da Ladra, Tiles of the Ribeira"
      assert payload.url == "/guide/near"

      text = Notifier.near_home_text(poet, picks, "https://poet.travel/guide/near")
      assert text =~ "- Feira da Ladra\n- Tiles of the Ribeira"
      assert text =~ "https://poet.travel/guide/near"
    end
  end

  describe "getting a home" do
    setup do
      Application.put_env(:traveling_poet, :destination_search, fn
        "Lisbon" ->
          {:ok,
           [
             %{
               place_name: "Lisboa, Portugal",
               kind: "city",
               city: "Lisboa",
               lat: 38.72,
               lng: -9.14,
               country_code: "pt"
             }
           ]}

        _ ->
          {:ok, []}
      end)

      on_exit(fn -> Application.delete_env(:traveling_poet, :destination_search) end)
      :ok
    end

    test "onboarding asks where the reader lives, and keeps it", %{conn: conn} do
      reader = user_fixture()
      {:ok, view, _html} = live(signed_in(conn, reader), ~p"/onboarding")
      render_click(view, "next", %{})
      html = render_click(view, "next", %{})
      assert html =~ "Where do you live?"

      html = view |> element("#onboarding-home-search") |> render_submit(%{home_query: "Nowhere"})
      assert html =~ "No places found."

      view |> element("#onboarding-home-search") |> render_submit(%{home_query: "Lisbon"})
      html = view |> element("#onboarding-home-0") |> render_click()
      assert html =~ ~s(id="onboarding-home-picked")

      render_click(view, "create_poet", %{})
      reader = Accounts.get_user!(reader.id)
      assert reader.home_place_name == "Lisboa, Portugal"
      assert reader.home_lat == 38.72
      assert reader.home_country_code == "pt"
    end

    test "onboarding without a home still finishes", %{conn: conn} do
      reader = user_fixture()
      {:ok, view, _html} = live(signed_in(conn, reader), ~p"/onboarding")
      render_click(view, "next", %{})
      render_click(view, "next", %{})
      render_click(view, "create_poet", %{})
      reader = Accounts.get_user!(reader.id)
      assert reader.onboarding_completed
      assert reader.home_lat == nil
    end

    test "the journal invites a reader with no home, and setting one says what is next", %{
      conn: conn
    } do
      reader = agent_user_fixture(%{onboarding_completed: true})
      poet = poet_fixture(reader, %{name: "Wren"})
      published_entry_fixture(poet)

      {:ok, view, html} = live(signed_in(conn, reader), ~p"/journal")
      assert html =~ ~s(id="near-home-invite")
      # Below the page, and the search waits behind "Set home"
      assert html =~ ~r/class="spread-wrap".*id="near-home-invite"/s
      assert has_element?(view, "#near-home-invite-open")
      assert has_element?(view, "#near-home-invite-search.hidden")

      view |> element("#near-home-invite-search") |> render_submit(%{query: "Lisbon"})
      refute has_element?(view, "#near-home-invite-search.hidden")
      html = view |> element("#near-home-invite-pick-0") |> render_click()

      refute html =~ ~s(id="near-home-invite")
      assert html =~ "Wren looks for things near you after the next page."
      assert Accounts.get_user!(reader.id).home_place_name == "Lisboa, Portugal"
    end

    test "No thanks switches Near you off and the invitation goes", %{conn: conn} do
      reader = agent_user_fixture(%{onboarding_completed: true})
      poet = poet_fixture(reader)
      published_entry_fixture(poet)

      {:ok, view, _html} = live(signed_in(conn, reader), ~p"/journal")
      html = view |> element("#near-home-invite-decline") |> render_click()

      refute html =~ ~s(id="near-home-invite")
      refute Accounts.get_user!(reader.id).near_home

      {:ok, _view, html} = live(signed_in(conn, reader), ~p"/journal")
      refute html =~ ~s(id="near-home-invite")
    end

    test "a reader with a home gets no invitation", %{conn: conn, user: user, poet: poet} do
      published_entry_fixture(poet)
      {:ok, _view, html} = live(signed_in(conn, user), ~p"/journal")
      refute html =~ ~s(id="near-home-invite")
    end
  end
end
