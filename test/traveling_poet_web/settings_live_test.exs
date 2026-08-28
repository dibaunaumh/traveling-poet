defmodule TravelingPoetWeb.SettingsLiveTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.Credits

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  test "shows balance, runway and packs; no header pill when healthy", %{conn: conn} do
    user = user_fixture(%{credits: 12, onboarding_completed: true})
    _poet = poet_fixture(user)

    {:ok, _view, html} = live(sign_in(conn, user), ~p"/settings")
    assert html =~ ~s(id="credits-balance")
    assert html =~ "12"
    assert html =~ "≈ 12 days of travel"
    assert html =~ "300 credits"
    assert html =~ "$100"
    assert html =~ "test mode"
    refute html =~ "Running low on credits"
  end

  test "low balance shows the warning and the header pill", %{conn: conn} do
    user = user_fixture(%{credits: 2, onboarding_completed: true})
    _poet = poet_fixture(user)

    {:ok, _view, html} = live(sign_in(conn, user), ~p"/settings")
    assert html =~ "Running low on credits"
    assert html =~ "≈ 2 days of travel"
  end

  test "balance updates live after a purchase", %{conn: conn} do
    user = user_fixture(%{credits: 1, onboarding_completed: true})
    _poet = poet_fixture(user)

    {:ok, view, _html} = live(sign_in(conn, user), ~p"/settings")
    {:ok, _} = Credits.purchase(user, "p10", "test:1")
    assert render(view) =~ "≈ 11 days of travel"
    assert render(view) =~ "Purchase"
  end

  test "exhausted balance shows the resting note", %{conn: conn} do
    user = user_fixture(%{onboarding_completed: true})
    _poet = poet_fixture(user)

    {:ok, _view, html} = live(sign_in(conn, user), ~p"/settings")
    assert html =~ "resting until you top up"
  end
end
