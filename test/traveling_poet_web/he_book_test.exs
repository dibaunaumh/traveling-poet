defmodule TravelingPoetWeb.HeBookTest do
  @moduledoc "The printed journal for a Hebrew reader (card-101)."
  use TravelingPoetWeb.ConnCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.Poets

  test "the book's front matter, chapters and colophon are in Hebrew, right to left",
       %{conn: conn} do
    user = user_fixture(%{onboarding_completed: true, locale: "he"})
    poet = poet_fixture(user, %{name: "Wren"})
    {:ok, _} = Poets.move_to(poet, %{lat: 38.72, lng: -9.13, place_name: "Lisbon, Portugal"})

    for i <- 0..1 do
      published_entry_fixture(poet, %{entry_date: Date.add(~D[2026-01-01], i), title: "Page #{i}"})
    end

    html =
      conn
      |> Plug.Test.init_test_session(%{user_id: user.id})
      |> get(~p"/journal/book")
      |> html_response(200)

    assert html =~ ~s(lang="he")
    assert html =~ ~s(dir="rtl")

    assert html =~ "תוכן העניינים"
    refute html =~ ">Contents<"
    assert html =~ "פרק 1"
    refute html =~ "Chapter 1"
    assert html =~ "2 ימים"
    refute html =~ "2 days"
    assert html =~ "היומן ממשיך ב-"
    refute html =~ "The journal continues at"
    assert html =~ "Wren: הספר"

    # the poet's words are not the interface's to translate
    assert html =~ "Page 1"
  end
end
