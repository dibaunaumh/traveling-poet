defmodule TravelingPoetWeb.FunnelAdminLiveTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.Analytics

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  test "non-admins are sent home", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} =
             live(sign_in(conn, user_fixture()), ~p"/admin/funnel")
  end

  test "shows the funnel, pages, clicks and who is stuck in onboarding", %{conn: conn} do
    Analytics.record(%{visitor: "a", name: "pageview", path: "/", referrer_host: "t.co"})
    Analytics.record(%{visitor: "a", name: "click", path: "/", target: "cta-hero-place"})
    Analytics.record(%{visitor: "b", name: "pageview", path: "/p/nam", viewport: "mobile"})
    user_fixture(%{email: "stuck@example.com", onboarding_step: "journey"})
    admin = user_fixture(%{is_admin: true, onboarding_completed: true})

    {:ok, view, html} = live(sign_in(conn, admin), ~p"/admin/funnel")

    assert html =~ "Visitor funnel"
    assert view |> element("#funnel tbody tr:first-child") |> render() =~ "2"
    assert html =~ "cta-hero-place"
    assert html =~ "/p/nam"
    assert html =~ "t.co"
    assert html =~ "stuck@example.com"

    assert render_click(view, "range", %{"days" => "30"}) =~ "Visitor funnel"
  end
end
