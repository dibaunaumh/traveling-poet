defmodule TravelingPoetWeb.JournalLiveTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.Journal

  defp publish_entry(poet, date, title) do
    {:ok, entry} = Journal.upsert_entry(poet.id, date, %{title: title, place_name: "Lisbon"})
    {:ok, _} = Journal.replace_sections(entry, [%{kind: "description", body: "a day"}])
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

  test "public journal renders with multiple entries", %{conn: conn} do
    user = agent_user_fixture()
    poet = poet_fixture(user, %{is_public: true})

    publish_entry(poet, ~D[2026-08-25], "Day one")
    publish_entry(poet, ~D[2026-08-26], "Day two")

    {:ok, _view, html} = live(conn, ~p"/p/#{poet.slug}")
    assert html =~ "Day two"
    assert html =~ "earlier"
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
