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

  test "new poet without entries sees the setting-up screen", %{conn: conn} do
    user = agent_user_fixture(%{onboarding_completed: true})
    poet = poet_fixture(user)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, html} = live(conn, ~p"/journal")

    assert html =~ "#{poet.name} is getting ready"
    assert html =~ "5–10 minutes"
    refute html =~ "poet-map"

    # escape hatch reveals the real UI
    html = view |> element("button", "peek behind the curtain") |> render_click()
    assert html =~ "poet-map"
  end
end
