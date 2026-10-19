defmodule TravelingPoetWeb.HeNotebookTest do
  @moduledoc "The notebook's own words for a Hebrew reader (card-101)."
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.Journal

  setup %{conn: conn} do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil, locale: "he"})
    poet = poet_fixture(user, %{name: "Nam"})

    {:ok, entry} =
      Journal.upsert_entry(poet.id, ~D[2026-08-25], %{title: "The rooftop", place_name: "Lisbon"})

    {:ok, _} = Journal.replace_sections(entry, [%{kind: "description", body: "coffee at noon"}])
    {:ok, entry} = Journal.publish_entry(entry)

    place_fixture(poet, entry, %{name: "Cafe Museum", category: "cafe", position: 0})

    %{conn: Plug.Test.init_test_session(conn, %{user_id: user.id})}
  end

  test "the Places spread speaks Hebrew around the poet's words", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/journal/2026-08-25?spread=places")

    assert html =~ "ההמלצות של Nam"
    refute html =~ "Where Nam would send you"
    assert html =~ "יום 1"
    refute html =~ ">Day 1<"
    assert html =~ "1 תחנה, 0 מהן על המפה."
    refute html =~ "on the map."

    # the poet's own words stay as written
    assert html =~ "The rooftop"
    assert html =~ "Cafe Museum"
  end

  test "the Today spread's chrome is Hebrew too", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/journal/2026-08-25")

    assert html =~ ~s(aria-label="הכפולות של העמוד הזה")
    refute html =~ "Pages of this entry"
  end
end
