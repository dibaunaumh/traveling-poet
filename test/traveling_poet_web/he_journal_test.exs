defmodule TravelingPoetWeb.HeJournalTest do
  @moduledoc """
  The journal's chrome in Hebrew (card-101): the owner's journal, the wait
  for the first page, the chat panel, the public journal and a shared Saved
  list, for a reader whose locale is "he". The poet's own words stay as
  written; only the interface around them changes.
  """
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Bookmarks, Journal}

  defp signed_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  defp publish_entry(poet, date) do
    {:ok, entry} =
      Journal.upsert_entry(poet.id, date, %{title: "The rooftop", place_name: "Lisbon"})

    {:ok, _} =
      Journal.replace_sections(entry, [%{kind: "description", body: "coffee at Cafe Museum"}])

    {:ok, _} = Journal.publish_entry(entry)
    entry
  end

  test "the owner's journal, its chat and its feedback row are in Hebrew", %{conn: conn} do
    user =
      agent_user_fixture(%{locale: "he", onboarding_completed: true, sprite_url: nil})

    poet = poet_fixture(user, %{name: "Wren"})
    publish_entry(poet, ~D[2026-08-25])

    {:ok, _view, html} = live(signed_in(conn, user), ~p"/journal")

    assert html =~ "ספרו מה חשבתם:"
    refute html =~ "Tell your poet:"
    assert html =~ "משוב פרטי, שמשפיע על הכיוון של העמודים הבאים"
    assert html =~ ~s(placeholder="כתבו ל-Wren…")
    refute html =~ "Write to Wren"
    assert html =~ ~s(aria-label="סימון משוב")
    refute html =~ "Feedback marker"
    assert html =~ "שיתוף העמוד"
    refute html =~ "Share this page"
    # the poet's words are untouched
    assert html =~ "The rooftop"
  end

  test "the wait for the first page is in Hebrew", %{conn: conn} do
    user =
      agent_user_fixture(%{locale: "he", onboarding_completed: true, sprite_url: nil})

    poet_fixture(user, %{name: "Wren"})

    {:ok, _view, html} = live(signed_in(conn, user), ~p"/journal")

    assert html =~ "בזמן ההמתנה"
    refute html =~ ~s(<h3 class="font-semibold">While you wait</h3>)
    assert html =~ "בינתיים"
    refute html =~ "In the meantime"
    assert html =~ "העמוד הראשון"
    refute html =~ "The first entry"
  end

  test "an English reader still sees English", %{conn: conn} do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    poet = poet_fixture(user, %{name: "Wren"})
    publish_entry(poet, ~D[2026-08-25])

    {:ok, _view, html} = live(signed_in(conn, user), ~p"/journal")

    assert html =~ "Tell your poet:"
    assert html =~ ~s(placeholder="Write to Wren…")
    refute html =~ "ספרו מה חשבתם:"
  end

  test "a public journal's chrome is in Hebrew for a Hebrew reader", %{conn: conn} do
    owner = user_fixture()
    poet = poet_fixture(owner, %{name: "Wren", is_public: true, status: "active"})
    publish_entry(poet, ~D[2026-08-25])
    reader = user_fixture(%{locale: "he"})

    {:ok, _view, html} = live(signed_in(conn, reader), ~p"/p/#{poet.slug}")

    assert html =~ "דיווח על היומן הזה"
    refute html =~ "Report this journal"
    assert html =~ "שירה בדרכים"
    refute html =~ "a traveling poet"
  end

  test "a shared Saved list is in Hebrew for a Hebrew reader", %{conn: conn} do
    owner = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil, name: "Maya Levi"})
    poet = poet_fixture(owner)
    entry = published_entry_fixture(poet)
    cafe = place_fixture(poet, entry, %{name: "Charlotte", lat: 50.06, lng: 19.93})
    {:ok, _} = Bookmarks.toggle(owner.id, "place", cafe.id)
    {:ok, %{saved_share_token: token}} = Bookmarks.share(owner)
    reader = user_fixture(%{locale: "he"})

    {:ok, _view, html} = live(signed_in(conn, reader), ~p"/shared/#{token}")

    assert html =~ "המקומות השמורים של Maya"
    refute html =~ "Maya&#39;s saved places"
    assert html =~ "שיתוף מתוך"
    assert html =~ "Traveling <em>Poet</em>"
  end
end
