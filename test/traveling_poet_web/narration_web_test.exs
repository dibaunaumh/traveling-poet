defmodule TravelingPoetWeb.NarrationWebTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Journal, Poets}
  alias TravelingPoet.Email.EntryEmail

  defp narrated(user, attrs \\ %{}) do
    poet = poet_fixture(user, Map.merge(%{name: "Wren", is_public: false}, attrs))
    entry = published_entry_fixture(poet, %{title: "Tram 28", entry_date: ~D[2026-10-14]})

    {:ok, _} =
      Journal.replace_sections(entry, [%{kind: "description", body: "Rails everywhere."}])

    narration =
      media_fixture(poet, %{
        journal_entry_id: entry.id,
        kind: "narration",
        content_type: "audio/mpeg",
        s3_key: "media/narration-#{entry.id}-abc.mp3",
        sources: %{"items" => []},
        duration_seconds: 310,
        alt_text: "Wren reads this page"
      })

    {poet, entry, narration}
  end

  test "the owner's page and a public page carry the player; a private page without narration has none",
       %{
         conn: conn
       } do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    {poet, _entry, narration} = narrated(user)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, _view, html} = live(conn, ~p"/journal/2026-10-14")
    assert html =~ ~s(id="listen")
    assert html =~ "Listen, 5 min"
    assert html =~ ~s(src="/media/#{narration.id}")
    assert html =~ ~s(preload="none")
    # The notebook's own control, not the browser's dark bar.
    assert html =~ ~s(phx-hook="NarrationPlayer")
    refute html =~ ~r/<audio[^>]*\scontrols/

    {:ok, _} = Poets.update_poet(poet, %{is_public: true})
    {:ok, _view, html} = live(build_conn(), ~p"/p/#{poet.slug}/2026-10-14")
    assert html =~ ~s(src="/media/#{narration.id}")

    other = poet_fixture(user_fixture(), %{is_public: true})
    published_entry_fixture(other, %{title: "Quiet", entry_date: ~D[2026-10-14]})
    {:ok, _view, html} = live(build_conn(), ~p"/p/#{other.slug}/2026-10-14")
    refute html =~ ~s(id="listen")
  end

  test "the audio is served by sending the browser to the bucket, under the drawing's rules", %{
    conn: conn
  } do
    user = user_fixture()
    {_poet, _entry, narration} = narrated(user)

    # a stranger on a private journal
    assert conn |> get(~p"/media/#{narration.id}") |> response(403)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    conn = get(conn, ~p"/media/#{narration.id}")
    assert redirected_to(conn, 302) =~ "https://bucket.example/get/media/narration-"
    assert redirected_to(conn, 302) =~ "as=inline"
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
  end

  defp unnarrated(user, attrs \\ %{}) do
    poet = poet_fixture(user, Map.merge(%{name: "Wren", is_public: true}, attrs))
    entry = published_entry_fixture(poet, %{title: "Tram 28", entry_date: ~D[2026-10-14]})

    {:ok, _} =
      Journal.replace_sections(entry, [%{kind: "description", body: "Rails everywhere."}])

    {poet, entry}
  end

  test "an owner who has not turned the reading on is offered it on the page, once; public readers are not",
       %{conn: conn} do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    {poet, _entry} = unnarrated(user)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, html} = live(conn, ~p"/journal/2026-10-14")
    assert html =~ ~s(id="listen-invite")
    assert html =~ "Hear your pages read aloud"
    refute html =~ ~s(id="listen")

    {:ok, _public, public_html} = live(build_conn(), ~p"/p/#{poet.slug}/2026-10-14")
    refute public_html =~ "listen-invite"

    view |> element("#listen-invite button", "Not now") |> render_click()
    refute render(view) =~ "listen-invite"
    assert Poets.get_poet_by_user(user.id).settings["narration_invite"] == "dismissed"
    refute Poets.get_poet_by_user(user.id).settings["narration"]

    {:ok, _view, html} = live(conn, ~p"/journal/2026-10-14")
    refute html =~ "listen-invite"
  end

  test "Turn it on is the Settings switch in place, and the offer goes away", %{conn: conn} do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    {_poet, _entry} = unnarrated(user)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, ~p"/journal/2026-10-14")

    view |> element("#listen-invite button", "Turn it on") |> render_click()
    html = render(view)
    refute html =~ "listen-invite"
    assert html =~ "Reading this page now"
    assert Poets.get_poet_by_user(user.id).settings["narration"] == true

    {:ok, _view, settings} = live(conn, ~p"/settings")
    assert settings =~ ~r/name="narration"[^>]*checked/
  end

  test "a reader who turned the reading on, or whose page is already read, gets no offer",
       %{conn: conn} do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    {_poet, _entry, _narration} = narrated(user, %{settings: %{"narration" => true}})

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, _view, html} = live(conn, ~p"/journal/2026-10-14")
    assert html =~ ~s(id="listen")
    refute html =~ "listen-invite"
  end

  test "the Settings switch is off until the reader turns the reading on", %{conn: conn} do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    poet_fixture(user, %{name: "Wren"})

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, html} = live(conn, ~p"/settings")
    assert html =~ "Read aloud"
    refute html =~ ~r/name="narration"[^>]*checked/

    render_change(view, "save_poet", %{"poet_name" => "Wren", "narration" => "on"})
    assert Poets.get_poet_by_user(user.id).settings["narration"] == true
    assert render(view) =~ ~r/name="narration"[^>]*checked/

    render_change(view, "save_poet", %{"poet_name" => "Wren", "telegram_notify" => "on"})
    assert Poets.get_poet_by_user(user.id).settings["narration"] == false
  end

  test "the page email offers the reading when the poet reads aloud" do
    base = %{
      user: %{email: "r@example.com"},
      poet: %{name: "Wren", current_place_name: "Lisbon"},
      entry: %{
        title: "Tram 28",
        teaser: "Rails.",
        place_name: "Lisbon",
        entry_date: ~D[2026-10-14],
        id: 1,
        excursion: nil
      },
      day: 3,
      drawing_url: nil,
      page_url: "https://poet.travel/journal/2026-10-14",
      unsubscribe_url: "https://poet.travel/email/unsubscribe/x"
    }

    quiet = EntryEmail.build(base)
    refute quiet.html =~ "listen"

    read = EntryEmail.build(Map.merge(base, %{listen?: true, listen_minutes: 6}))

    assert read.html =~
             ~s(href="https://poet.travel/journal/2026-10-14#listen">or listen, about 6 minutes</a>)

    assert read.text =~ "Or listen, about 6 minutes"
  end
end
