defmodule TravelingPoetWeb.AboutYouLiveTest do
  @moduledoc "The About you note in Settings (card-125, dec-011)."
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.ReaderNote

  setup %{conn: conn} do
    user = user_fixture(%{onboarding_completed: true})
    poet = poet_fixture(user, %{name: "Nam"})
    %{conn: Plug.Test.init_test_session(conn, %{user_id: user.id}), poet: poet}
  end

  test "before the poet writes it, the reader can write it themselves", %{conn: conn, poet: poet} do
    {:ok, view, html} = live(conn, ~p"/settings")
    assert html =~ ~s(id="about")
    assert html =~ "Nam writes them after its next page"

    view
    |> form("#reader-note-form", %{"text" => "I travel for coffee and old maps."})
    |> render_submit()

    assert %{text: "I travel for coffee and old maps.", written_by: "reader"} =
             ReaderNote.get(poet.id)

    assert render(view) =~ "In your words."
  end

  test "the poet's draft is shown for the reader to change", %{conn: conn, poet: poet} do
    {:ok, _} = ReaderNote.draft(poet.id, "You travel for specialty coffee.")
    {:ok, _view, html} = live(conn, ~p"/settings")
    assert html =~ "Nam wrote this from what it knows of you."
    assert html =~ "You travel for specialty coffee."
  end

  test "a suggested line is added with one tap, or declined", %{conn: conn, poet: poet} do
    {:ok, _} = ReaderNote.save(poet.id, "I travel for coffee.")
    {:ok, add} = ReaderNote.suggest(poet.id, %{kind: "add", text: "You follow kit airplanes."})
    {:ok, other} = ReaderNote.suggest(poet.id, %{kind: "add", text: "You love opera."})

    {:ok, view, html} = live(conn, ~p"/settings")
    assert html =~ "Nam suggests adding:"
    assert html =~ "You follow kit airplanes."

    view |> element("#note-line-#{add.id} button", "Add it") |> render_click()
    assert ReaderNote.get(poet.id).text == "I travel for coffee. You follow kit airplanes."

    html = view |> element("#note-line-#{other.id} button", "No thanks") |> render_click()
    refute html =~ "You love opera."
    assert ReaderNote.pending(poet.id) == []
  end
end
