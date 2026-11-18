defmodule TravelingPoetWeb.JournalDrawingLoadingTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.Journal

  # In the iPhone app the day's drawing was a lazy <img> with no size of its
  # own, and WebKit never fetched it: the caption and its sources stood in an
  # empty frame until the phone was turned sideways (Udi, 2026-11-17, Nam and
  # Saoirse). The page's drawings are asked for at once, as Discover's are.
  setup %{conn: conn} do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    poet = poet_fixture(user)

    {:ok, entry} =
      Journal.upsert_entry(poet.id, ~D[2026-11-17], %{title: "Comics", place_name: "Vancouver"})

    drawing = media_fixture(poet, %{journal_entry_id: entry.id, alt_text: "Wing Sang Building"})

    {:ok, _} =
      Journal.replace_sections(entry, [
        %{kind: "description", body: "A morning in Chinatown."},
        %{kind: "illustration", media_id: drawing.id}
      ])

    {:ok, _entry} = Journal.publish_entry(entry)
    %{conn: conn, user: user, poet: poet, drawing: drawing}
  end

  test "the owner's journal asks for the drawing at once", %{conn: conn, user: user} = ctx do
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, ~p"/journal")

    assert has_element?(view, ~s|img[src="/media/#{ctx.drawing.id}"][loading=eager]|)
    refute has_element?(view, ~s|img[src="/media/#{ctx.drawing.id}"][loading=lazy]|)
  end

  test "so does the public page", %{conn: conn, poet: poet} = ctx do
    {:ok, view, _html} = live(conn, ~p"/p/#{poet.slug}")

    assert has_element?(view, ~s|img[src="/media/#{ctx.drawing.id}"][loading=eager]|)
  end
end
