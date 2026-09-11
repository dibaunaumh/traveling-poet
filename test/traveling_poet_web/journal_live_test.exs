defmodule TravelingPoetWeb.JournalLiveTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.Journal

  defp publish_entry(poet, date, title) do
    {:ok, entry} = Journal.upsert_entry(poet.id, date, %{title: title, place_name: "Lisbon"})

    {:ok, _} =
      Journal.replace_sections(entry, [
        %{kind: "description", body: "a day, coffee at Cafe Museum"}
      ])

    {:ok, _} = Journal.publish_entry(entry)
    entry
  end

  test "journal renders with multiple entries (date nav uses ISO params)", %{conn: conn} do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    poet = poet_fixture(user)

    publish_entry(poet, ~D[2026-08-25], "Day one")
    publish_entry(poet, ~D[2026-08-26], "Day two")

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})

    # newest entry shows, with a working "earlier" link — this render crashed
    # when entry_nav emitted Date structs into ~p (no Phoenix.Param for Date)
    {:ok, view, html} = live(conn, ~p"/journal")
    assert html =~ "Day two"
    assert html =~ "earlier"

    {:error, {:live_redirect, %{to: to}}} = view |> element("a", "earlier") |> render_click()
    assert to == "/journal/2026-08-25"

    {:ok, _view, html} = live(conn, to)
    assert html =~ "Day one"
  end

  test "the entry opens as a spread with index tabs; an unknown spread falls back to Today",
       %{conn: conn} do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    poet = poet_fixture(user)
    entry = publish_entry(poet, ~D[2026-08-25], "The rooftop")
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})

    {:ok, view, html} = live(conn, ~p"/journal/2026-08-25?spread=garbage")

    assert html =~ ~s(role="tablist")

    assert [today] =
             html
             |> LazyHTML.from_document()
             |> LazyHTML.query(~s(a[role="tab"][aria-selected="true"]))
             |> LazyHTML.to_tree()

    # an entry from August is not "Today": the tab carries its date
    assert LazyHTML.text(LazyHTML.from_tree([today])) =~ "Aug 25"
    # the Chat tab shows whether the sidebar is out (open by default) and says what a tap does
    assert html =~ ~s(title="Hide the chat")
    html = view |> element(~s(button.spread-tab[phx-click="toggle_chat"])) |> render_click()
    assert html =~ ~s(title="Show the chat")
    assert html =~ "Chat"
    assert html =~ ~s(class="notebook-page spread-page spread-left")
    assert html =~ ~s(id="section-#{entry.id}-0")
    assert html =~ ~s(class="notebook-page spread-page spread-right)

    # turning a tab is a patch on the same date: the entry stays put
    html = view |> element(~s(a[role="tab"]), "Aug 25") |> render_click()
    assert html =~ "The rooftop"
    assert_patch(view, ~p"/journal/2026-08-25?spread=today")
  end

  test "the Places spread lists the day's stops under stamps and pins them on the map",
       %{conn: conn} do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    poet = poet_fixture(user, %{name: "Nam"})
    entry = publish_entry(poet, ~D[2026-08-25], "The rooftop")

    place_fixture(poet, entry, %{
      name: "Cafe Museum",
      category: "cafe",
      lat: 48.2,
      lng: 16.37,
      geocode_status: "ok",
      poet_rating: 4,
      blurb: "Loos designed it.",
      source_url: "https://example.com/cafe-museum",
      position: 0
    })

    place_fixture(poet, entry, %{name: "Unplaced Bar", category: "restaurant", position: 1})

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, html} = live(conn, ~p"/journal/2026-08-25?spread=places")

    assert html =~ "Where Nam would send you"
    assert html =~ "Cafe Museum"
    assert html =~ ~s(id="stop-)

    # on Today, the first mention in the prose links to that stop
    {:ok, _view, today} = live(conn, ~p"/journal/2026-08-25")
    assert today =~ ~s(<a href="/journal/2026-08-25?spread=places#stop-)
    assert html =~ "Unplaced Bar"
    assert html =~ "Nam&#39;s pick"
    assert html =~ ~s(href="https://example.com/cafe-museum")
    assert html =~ "2 stops, 1 on the map."
    assert html =~ ~s(class="place-stamp")
    # the journey map moved into the left page, carrying the stops as pins
    assert html =~ ~s(id="poet-map")
    assert html =~ ~s(class="taped-map-canvas z-0")
    assert_push_event(view, "map:update", %{places: [%{name: "Cafe Museum", n: 1}]})
    refute html =~ ~s(phx-hook="Markers")

    # back to Today: the pins leave the payload
    view |> element(~s(a[role="tab"]), "Aug 25") |> render_click()
    assert_push_event(view, "map:update", %{places: []})
  end

  test "a spot drawing embedded in the prose renders on the page with its sources; foreign media does not",
       %{conn: conn} do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    poet = poet_fixture(user)
    other = poet_fixture(user_fixture())

    {:ok, entry} =
      Journal.upsert_entry(poet.id, ~D[2026-08-25], %{title: "Ink", place_name: "Ronda"})

    spot =
      media_fixture(poet, %{
        journal_entry_id: entry.id,
        kind: "spot",
        alt_text: "a cup of cafe con leche",
        sources: %{"items" => [%{"url" => "https://example.com/cup", "label" => "the cafe"}]}
      })

    foreign = media_fixture(other, %{journal_entry_id: nil})

    body =
      "The morning started slow.\n\n![a cup of cafe con leche](/media/#{spot.id})\n\n" <>
        "Then the bridge. ![stolen](/media/#{foreign.id}) ![online](https://photos.example/x.jpg)"

    {:ok, _} = Journal.replace_sections(entry, [%{kind: "description", body: body}])
    {:ok, _} = Journal.publish_entry(entry)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, _view, html} = live(conn, ~p"/journal/2026-08-25")

    # the drawing is the citation: it links to what it was drawn from
    assert html
           |> LazyHTML.from_document()
           |> LazyHTML.query(
             ~s|.prose a[href="https://example.com/cup"][title="Drawn from the cafe"] img[src="/media/#{spot.id}"]|
           )
           |> Enum.count() == 1

    refute html =~ ~s(src="/media/#{foreign.id}")
    refute html =~ "photos.example"
    assert html =~ "Ink drawing drawn from"
    assert html =~ ~s(href="https://example.com/cup")
  end

  test "an entry without places still has the tab, and says so", %{conn: conn} do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    poet = poet_fixture(user)
    publish_entry(poet, ~D[2026-08-25], "Quiet")
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})

    {:ok, _view, html} = live(conn, ~p"/journal/2026-08-25?spread=places")
    assert html =~ "No places logged for this day"
    assert html =~ "Nowhere in particular today."
    assert html =~ ~s(href="/guide")
  end

  test "public journal renders with multiple entries", %{conn: conn} do
    user = agent_user_fixture()
    poet = poet_fixture(user, %{is_public: true})

    publish_entry(poet, ~D[2026-08-25], "Day one")
    publish_entry(poet, ~D[2026-08-26], "Day two")

    {:ok, _view, html} = live(conn, ~p"/p/#{poet.slug}")
    assert html =~ "Day two"
    assert html =~ "earlier"
    # the journey day is the app's count, shown ahead of the poet's title
    assert html =~ ~s(class="notebook-day">Day 2</span>)
    # the same spread and tabs as the owner sees, minus chat
    assert html =~ ~s(role="tablist")
    assert html =~ ~s(href="/p/#{poet.slug}/2026-08-26?spread=today")
    assert html =~ ~s(href="/p/#{poet.slug}/2026-08-26?spread=places")
    refute html =~ "toggle_chat"

    {:ok, view, html} = live(conn, ~p"/p/#{poet.slug}/2026-08-26?spread=places")
    assert html =~ ~s(id="public-poet-map")
    assert html =~ "No places logged for this day"
    assert_push_event(view, "map:update", %{places: []})
  end

  test "a shared public entry carries link-preview tags; the owner's journal does not", %{
    conn: conn
  } do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    poet = poet_fixture(user, %{is_public: true})
    publish_entry(poet, ~D[2026-08-25], "Day one")

    {:ok, entry} =
      Journal.upsert_entry(poet.id, ~D[2026-08-27], %{
        title: "The rooftop nobody mentions",
        teaser: "Swifts at dusk over the mosque.",
        place_name: "Cordoba"
      })

    {:ok, _} = Journal.publish_entry(entry)

    html = conn |> get(~p"/p/#{poet.slug}/2026-08-27") |> html_response(200)
    assert html =~ ~s(property="og:title" content="Day 3: The rooftop nobody mentions")
    assert html =~ ~s(property="og:description" content="Swifts at dusk over the mosque.")
    assert html =~ ~s(content="http://localhost:4000/p/#{poet.slug}/2026-08-27")
    refute html =~ "og:image"

    owner = Plug.Test.init_test_session(conn, %{user_id: user.id})
    refute owner |> get(~p"/journal/2026-08-27") |> html_response(200) =~ "og:title"
  end

  test "a long setup says so, and shows how long it has been", %{conn: conn} do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    poet = poet_fixture(user)

    # Backdate creation: the fleet's slowest real setup ran 20 minutes, and the
    # screen used to keep promising "5-10" straight through it.
    poet
    |> Ecto.Changeset.change(
      inserted_at:
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(-25, :minute)
        |> NaiveDateTime.truncate(:second)
    )
    |> TravelingPoet.Repo.update!()

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, _view, html} = live(conn, ~p"/journal")

    assert html =~ "taking longer than usual"
    assert html =~ "25 minutes"
  end

  describe "before the first entry" do
    test "with no sprite yet: the setup card, no chat, no escape hatch", %{conn: conn} do
      user = user_fixture(%{onboarding_completed: true, sprite_provisioned: false})
      poet = poet_fixture(user)

      conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
      {:ok, view, html} = live(conn, ~p"/journal")

      assert html =~ ~s(id="setup-card")
      assert html =~ "Setting up #{poet.name}"
      assert html =~ "Working on it"
      assert html =~ ~s(id="journey-tour")
      refute html =~ ~s(id="poet-map")
      assert html =~ ~s(id="waiting-tips")
      refute html =~ ~s(id="chat-sidebar-panel")
      refute html =~ ~s(id="first-entry-placeholder")
      refute html =~ "peek behind"

      # A step broadcast moves the card along: the two earlier stages are done,
      # the packing stage is active, the last one still pending.
      send(view.pid, {:provision_step, :write_workspace})
      html = render(view)
      assert html =~ "Packing notebook, pens and maps"
      refute html =~ "Working on it"
    end

    test "with a sprite: the real page, a placeholder and the chat", %{conn: conn} do
      user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
      poet = poet_fixture(user)

      conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
      {:ok, _view, html} = live(conn, ~p"/journal")

      assert html =~ ~s(id="first-entry-placeholder")
      assert html =~ "#{poet.name} is awake and about to open the notebook"
      assert html =~ ~s(id="chat-sidebar-panel")
      assert html =~ ~s(id="journey-tour")
      assert html =~ "While you wait"
      refute html =~ ~s(id="setup-card")
    end

    test "an attempt in flight says so on the page and above the composer", %{conn: conn} do
      user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
      poet = poet_fixture(user)
      {:ok, _} = TravelingPoet.Usage.record(user.id, "first_entry_attempt")

      conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
      {:ok, _view, html} = live(conn, ~p"/journal")

      assert html =~ "#{poet.name} is writing the first entry"
      assert html =~ ~s(id="chat-first-entry-hint")
    end

    test "the first entry replaces the placeholder", %{conn: conn} do
      user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
      poet = poet_fixture(user)

      conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
      {:ok, view, _html} = live(conn, ~p"/journal")

      entry = publish_entry(poet, Date.utc_today(), "Setting out")
      send(view.pid, {:journal_published, entry.id})

      html = render(view)
      assert html =~ "Setting out"
      refute html =~ ~s(id="first-entry-placeholder")
      refute html =~ ~s(id="waiting-tips")
      refute html =~ ~s(id="journey-tour")
      assert html =~ ~s(id="poet-map")
    end

    test "the tour shows the fleet's journeys and marks where yours starts", %{conn: conn} do
      user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
      poet = poet_fixture(user, %{name: "Ada"})

      other = poet_fixture(user_fixture(), %{name: "Nam", is_public: true, status: "active"})

      {:ok, entry} =
        Journal.upsert_entry(other.id, ~D[2026-09-01], %{
          title: "Rain on Gran Via",
          place_name: "Madrid",
          lat: 40.4,
          lng: -3.7
        })

      {:ok, _} = Journal.replace_sections(entry, [%{kind: "description", body: "a day"}])
      {:ok, entry} = Journal.publish_entry(entry)
      media_fixture(other, %{journal_entry_id: entry.id, alt_text: "a wet street"})

      poet_fixture(user_fixture(), %{
        name: "Hidden Hilda",
        is_public: false,
        status: "active",
        current_lat: 13.7524938,
        current_lng: 100.4935089,
        current_place_name: "Bangkok, Thailand"
      })

      conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
      {:ok, view, html} = live(conn, ~p"/journal")

      assert html =~ ~s(id="journey-tour")
      assert html =~ ~s(id="journey-tour-cards")
      assert html =~ ~s(data-tour-poet="#{other.slug}")
      assert html =~ "a wet street"
      assert html =~ ~s(data-tour-dot="0")
      assert html =~ "In the meantime"

      # The reader's own wait comes first; the fleet is what fills it.
      assert :binary.match(html, "first-entry-placeholder") <
               :binary.match(html, "In the meantime")

      assert :binary.match(html, "In the meantime") < :binary.match(html, ~s(id="journey-tour"))
      assert html =~ "2 poets on the road"
      assert html =~ "journals are private"
      assert html =~ "Ada"
      refute html =~ "Hidden Hilda"
      refute html =~ "Bangkok"

      # Another poet's publish refreshes the tour without touching the page.
      send(view.pid, {:journal_published, other.id, entry.id})
      html = render(view)
      assert html =~ ~s(data-tour-poet="#{other.slug}")
      assert html =~ ~s(id="first-entry-placeholder")
      assert poet.name == "Ada"
    end

    test "a turn the app started streams into the chat and is stored once", %{conn: conn} do
      user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
      _poet = poet_fixture(user)

      conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
      {:ok, view, _html} = live(conn, ~p"/journal")

      send(view.pid, {:gateway_event, {:text_delta, "Lacing my boots in Lisbon."}})
      assert render(view) =~ "Lacing my boots in Lisbon."

      # AgentSession persisted the same reply for the turn it drove.
      {:ok, _} =
        TravelingPoet.Chat.create_message(%{
          user_id: user.id,
          role: "agent",
          content: "Lacing my boots in Lisbon.",
          channel: "system"
        })

      send(view.pid, {:gateway_event, {:done, "r1"}})
      render(view)

      agent_messages =
        TravelingPoet.Chat.list_messages(user.id) |> Enum.filter(&(&1.role == "agent"))

      assert length(agent_messages) == 1
    end

    test "a message the gateway turns away mid-onboard is held, then sent when the turn ends",
         %{conn: conn} do
      user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
      _poet = poet_fixture(user)
      {:ok, _} = TravelingPoet.Usage.record(user.id, "first_entry_attempt")

      conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
      {:ok, view, _html} = live(conn, ~p"/journal")

      # The send itself stops at the readiness gate in the suite (no sprite
      # URL), which is enough to record what was sent.
      send(view.pid, {:chat_send, "hello there", false})
      send(view.pid, {:gateway_event, {:error, "Chat error"}})
      html = render(view)
      assert html =~ ~s(id="chat-held-note")
      assert html =~ "Held until"

      send(view.pid, {:gateway_event, {:done, "r1"}})
      html = render(view)
      refute html =~ ~s(id="chat-held-note")
      # The resend went back through the same gate.
      assert html =~ "isn&#39;t ready yet"
    end
  end

  test "onboarding scout flow gates Continue until a stop is added", %{conn: conn} do
    user = user_fixture(%{onboarding_completed: false})
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})

    {:ok, view, _html} = live(conn, ~p"/onboarding")

    # Step 1 arrives pre-filled; just continue.
    view |> element("form[phx-submit=next]") |> render_submit()

    assert render(view) =~ "Trip Scout"
    view |> element("button[phx-value-mode=scout]") |> render_click()

    # scout mode gates Continue until at least one stop is added
    # (adding stops exercises Nominatim, so network-bound paths stop here)
    html = render(view)
    assert html =~ "Add the places in the order"
    assert view |> element("button#journey-continue[disabled]") |> has_element?()
  end
end
