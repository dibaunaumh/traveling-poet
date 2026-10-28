defmodule TravelingPoetWeb.DrawingFeedbackLiveTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Journal, Markers}

  defp owner_with_drawing(conn) do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    poet = poet_fixture(user)

    {:ok, entry} =
      Journal.upsert_entry(poet.id, ~D[2026-09-01], %{title: "A day", place_name: "Budapest"})

    drawing = media_fixture(poet, %{journal_entry_id: entry.id, prompt: "the chain bridge"})

    {:ok, _} =
      Journal.replace_sections(entry, [
        %{kind: "description", body: "A river day."},
        %{kind: "illustration", media_id: drawing.id}
      ])

    {:ok, entry} = Journal.publish_entry(entry)
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {conn, user, poet, entry, drawing}
  end

  test "the four buttons sit under the main drawing", %{conn: conn} do
    {conn, _user, _poet, _entry, drawing} = owner_with_drawing(conn)
    {:ok, view, _html} = live(conn, ~p"/journal")

    assert has_element?(view, "#drawing-feedback-#{drawing.id}")

    for kind <- ~w(beautiful meh inaccurate made_up) do
      assert has_element?(view, "#rate-drawing-#{drawing.id}-#{kind}")
    end

    # the drawing-only kinds stay out of the marker menu
    refute has_element?(view, "#marker-menu .marker-made_up")
  end

  test "Made up asks what is wrong, and the note reaches the marker", %{conn: conn} do
    {conn, user, poet, entry, drawing} = owner_with_drawing(conn)
    {:ok, view, _html} = live(conn, ~p"/journal")

    view |> element("#rate-drawing-#{drawing.id}-made_up") |> render_click()

    assert [marker] = Markers.list_markers(entry.id)
    assert {marker.kind, marker.media_id, marker.user_id} == {"made_up", drawing.id, user.id}
    assert has_element?(view, "#rate-drawing-#{drawing.id}-made_up[aria-pressed=true]")
    assert render(view) =~ "#{poet.name} will redraw it once you have finished reading."

    view
    |> form("#drawing-note-#{drawing.id}",
      drawing_note: %{id: marker.id, note: "the bridge has no road on it"}
    )
    |> render_submit()

    assert [%{note: "the bridge has no road on it"}] = Markers.list_markers(entry.id)
    refute has_element?(view, "#drawing-note-#{drawing.id}")
    assert render(view) =~ "the bridge has no road on it"
  end

  test "Beautiful asks for no note, and pressing it again takes it back", %{conn: conn} do
    {conn, _user, _poet, entry, drawing} = owner_with_drawing(conn)
    {:ok, view, _html} = live(conn, ~p"/journal")

    view |> element("#rate-drawing-#{drawing.id}-beautiful") |> render_click()
    assert [%{kind: "beautiful"}] = Markers.list_markers(entry.id)
    refute has_element?(view, "#drawing-note-#{drawing.id}")

    view |> element("#rate-drawing-#{drawing.id}-beautiful") |> render_click()
    assert Markers.list_markers(entry.id) == []
  end

  test "Skip closes the note box and keeps the rating", %{conn: conn} do
    {conn, _user, _poet, entry, drawing} = owner_with_drawing(conn)
    {:ok, view, _html} = live(conn, ~p"/journal")

    view |> element("#rate-drawing-#{drawing.id}-inaccurate") |> render_click()
    view |> element("#drawing-note-#{drawing.id} button", "Skip") |> render_click()

    refute has_element?(view, "#drawing-note-#{drawing.id}")
    assert [%{kind: "inaccurate", note: nil}] = Markers.list_markers(entry.id)
  end

  test "a drawing that is not on the page cannot be rated", %{conn: conn} do
    {conn, _user, poet, entry, _drawing} = owner_with_drawing(conn)
    other = media_fixture(poet)
    {:ok, view, _html} = live(conn, ~p"/journal")

    render_click(view, "rate_drawing", %{"kind" => "meh", "media" => to_string(other.id)})
    assert Markers.list_markers(entry.id) == []
  end

  test "the poet reads a drawing back with the prompt that made it", %{conn: conn} do
    {_conn, user, _poet, entry, drawing} = owner_with_drawing(conn)

    body =
      conn
      |> put_req_header("authorization", "Bearer #{user.agent_api_token}")
      |> get(~p"/api/agent/journal_entries/#{Date.to_iso8601(entry.entry_date)}")
      |> json_response(200)

    assert [%{"id" => id, "prompt" => "the chain bridge", "sources" => [_]}] = body["media"]
    assert id == drawing.id
  end
end
