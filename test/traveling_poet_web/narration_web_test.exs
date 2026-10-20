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

  test "the owner's page and a public page carry the player, with the recording when there is one",
       %{
         conn: conn
       } do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    {poet, _entry, narration} = narrated(user)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, _view, html} = live(conn, ~p"/journal/2026-10-14")
    assert html =~ ~s(id="listen")
    assert html =~ "Listen, 5 min"
    assert html =~ ~s(data-src="/media/#{narration.id}")
    assert html =~ ~s(preload="none")
    # The notebook's own control, not the browser's dark bar.
    assert html =~ ~s(phx-hook="NarrationPlayer")
    refute html =~ ~r/<audio[^>]*\scontrols/

    {:ok, _} = Poets.update_poet(poet, %{is_public: true})
    {:ok, _view, html} = live(build_conn(), ~p"/p/#{poet.slug}/2026-10-14")
    assert html =~ ~s(data-src="/media/#{narration.id}")

    # A page nobody has listened to yet shows the same ring with an estimate.
    other = poet_fixture(user_fixture(), %{is_public: true})
    published_entry_fixture(other, %{title: "Quiet", entry_date: ~D[2026-10-14]})
    {:ok, _view, html} = live(build_conn(), ~p"/p/#{other.slug}/2026-10-14")
    assert html =~ ~s(id="listen")
    assert html =~ "Listen, about"
    refute html =~ "data-src="
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

  @frame_header <<0xFF, 0xFB, 0x90, 0x00>>

  defp mp3(seconds) do
    size = div(128_000 * seconds, 8)
    @frame_header <> :binary.copy(<<0>>, size - 4)
  end

  test "a page without a recording shows the player with an estimate, and a press reads it",
       %{conn: conn} do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    {_poet, entry} = unnarrated(user)
    Application.put_env(:traveling_poet, :openrouter_api_key, "test-key")
    on_exit(fn -> Application.put_env(:traveling_poet, :openrouter_api_key, nil) end)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, html} = live(conn, ~p"/journal/2026-10-14")
    assert html =~ ~s(id="listen")
    assert html =~ "Listen, about"
    refute html =~ "data-src="
    refute html =~ "listen-invite"

    Req.Test.stub(TravelingPoet.Narration, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("audio/mpeg")
      |> Plug.Conn.send_resp(200, mp3(300))
    end)

    Req.Test.allow(TravelingPoet.Narration, self(), view.pid)

    render_hook(view, "narration_request", %{})
    html = render(view)
    narration = TravelingPoet.Narration.narration_for(entry.id)
    assert narration
    assert html =~ ~s(data-src="/media/#{narration.id}")
    assert html =~ "Listen, 5 min"
    assert html =~ ~s(data-state="idle")
  end

  test "a long page waits longer for its reading, within bounds" do
    alias TravelingPoetWeb.Listening
    assert Listening.patience_ms(nil) == 45_000
    assert Listening.patience_ms(60) == 45_000
    # Shelly's first page: 273 s of reading took 45.2 s to make
    assert Listening.patience_ms(273) == 98_000
    assert Listening.patience_ms(3_000) == 200_000
  end

  test "a reading that outlasts the wait still arrives, and takes the notice away",
       %{conn: conn} do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    {_poet, entry} = unnarrated(user)
    Application.put_env(:traveling_poet, :openrouter_api_key, "test-key")
    Application.put_env(:traveling_poet, :narration_inline, false)
    Req.Test.set_req_test_to_shared()

    on_exit(fn ->
      Application.put_env(:traveling_poet, :openrouter_api_key, nil)
      Application.put_env(:traveling_poet, :narration_inline, true)
      Req.Test.set_req_test_to_private()
    end)

    test_pid = self()

    Req.Test.stub(TravelingPoet.Narration, fn conn ->
      send(test_pid, {:reading, self()})

      receive do
        :go -> :ok
      after
        5_000 -> :ok
      end

      conn
      |> Plug.Conn.put_resp_content_type("audio/mpeg")
      |> Plug.Conn.send_resp(200, mp3(300))
    end)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, ~p"/journal/2026-10-14")

    render_hook(view, "narration_request", %{})
    assert_receive {:reading, reader}, 2_000

    send(view.pid, {:narration_timeout, entry.id})
    assert render(view) =~ "The page could not be read just now"

    Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "poet:#{entry.poet_id}")
    send(reader, :go)
    assert_receive {:narration_ready, _}, 5_000

    html = render(view)
    narration = TravelingPoet.Narration.narration_for(entry.id)
    assert html =~ ~s(data-src="/media/#{narration.id}")
    refute html =~ "The page could not be read just now"
  end

  test "a public reader's press reads the page too, and the poet's daily cap is the guard",
       %{conn: _conn} do
    user = user_fixture()
    {poet, entry} = unnarrated(user)
    Application.put_env(:traveling_poet, :openrouter_api_key, "test-key")
    on_exit(fn -> Application.put_env(:traveling_poet, :openrouter_api_key, nil) end)

    {:ok, view, html} = live(build_conn(), ~p"/p/#{poet.slug}/2026-10-14")
    assert html =~ ~s(id="listen")
    assert html =~ "Listen, about"

    Req.Test.stub(TravelingPoet.Narration, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("audio/mpeg")
      |> Plug.Conn.send_resp(200, mp3(120))
    end)

    Req.Test.allow(TravelingPoet.Narration, self(), view.pid)
    render_hook(view, "narration_request", %{})
    narration = TravelingPoet.Narration.narration_for(entry.id)
    assert narration
    html = render(view)
    assert html =~ ~s(data-src="/media/#{narration.id}")
    assert html =~ "Listen, 2 min"

    # Over the cap, the press fails like any other and the ring comes back.
    Application.put_env(:traveling_poet, :daily_narration_cap, 0)
    on_exit(fn -> Application.delete_env(:traveling_poet, :daily_narration_cap) end)
    quiet = poet_fixture(user_fixture(), %{is_public: true})
    published_entry_fixture(quiet, %{title: "Quiet", entry_date: ~D[2026-10-14]})
    {:ok, view, _html} = live(build_conn(), ~p"/p/#{quiet.slug}/2026-10-14")
    render_hook(view, "narration_request", %{})
    html = render(view)
    assert html =~ "could not be read just now"
    assert html =~ ~s(data-state="idle")
    refute html =~ "data-src="
  end

  test "with no speech model configured there is no ring anywhere, and no offer", %{conn: conn} do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    {poet, _entry} = unnarrated(user)
    Application.put_env(:traveling_poet, :narration_model, nil)

    on_exit(fn ->
      Application.put_env(:traveling_poet, :narration_model, "test/narration-model")
    end)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, html} = live(conn, ~p"/journal/2026-10-14")
    refute html =~ ~s(id="listen")
    refute html =~ "listen-invite"
    render_hook(view, "narration_request", %{})
    refute render(view) =~ ~s(id="listen")

    {:ok, _view, html} = live(build_conn(), ~p"/p/#{poet.slug}/2026-10-14")
    refute html =~ ~s(id="listen")
  end

  test "Settings has no Read aloud switch: the reading is on for every page", %{conn: conn} do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    poet_fixture(user, %{name: "Wren"})

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, _view, html} = live(conn, ~p"/settings")
    refute html =~ "Read aloud"
    refute html =~ ~s(name="narration")
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
