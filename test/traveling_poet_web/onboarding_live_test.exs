defmodule TravelingPoetWeb.OnboardingLiveTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  defp at_poet_step(conn) do
    user = user_fixture()
    {:ok, view, _html} = live(sign_in(conn, user), ~p"/onboarding")

    # Step 1 → step 2
    view
    |> form("form", %{"name" => "Udi", "interests" => "bridges, street food"})
    |> render_submit()

    view
  end

  test "picking a book keeps the name, personality and chattiness already typed", %{conn: conn} do
    view = at_poet_step(conn)

    # Typing, before pressing Continue — this is what phx-change now captures.
    view
    |> form("form", %{
      "poet_name" => "Wren",
      "personality" => "melancholy but funny; talks to cats",
      "verbosity" => "expansive"
    })
    |> render_change()

    # ...then the click that used to wipe the lot.
    html = render_click(view, "toggle_reading", %{"idx" => "0"})

    assert html =~ "Wren"
    assert html =~ "melancholy but funny; talks to cats"

    assert html =~ ~r/value="expansive"[^>]*checked/s or
             html =~ ~r/checked[^>]*value="expansive"/s
  end

  test "the answers survive stepping back and forward again", %{conn: conn} do
    view = at_poet_step(conn)

    view
    |> form("form", %{"poet_name" => "Wren", "personality" => "obsessed with bridges"})
    |> render_change()

    render_click(view, "next", %{})
    html = render_click(view, "back", %{})

    assert html =~ "Wren"
    assert html =~ "obsessed with bridges"
  end

  test "step 1 answers survive a re-render too", %{conn: conn} do
    user = user_fixture()
    {:ok, view, _html} = live(sign_in(conn, user), ~p"/onboarding")

    view
    |> form("form", %{"name" => "Udi", "interests" => "hidden gardens"})
    |> render_change()

    html = render_click(view, "next", %{}) |> then(fn _ -> render_click(view, "back", %{}) end)

    assert html =~ "Udi"
    assert html =~ "hidden gardens"
  end
end
