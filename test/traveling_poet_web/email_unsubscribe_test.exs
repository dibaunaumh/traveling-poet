defmodule TravelingPoetWeb.EmailUnsubscribeTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.Accounts
  alias TravelingPoet.Email.Notifier

  test "the link opens a page; only the button (or a mail app's one-click POST) stops the emails",
       %{conn: conn} do
    user = user_fixture()
    token = Notifier.unsubscribe_token(user)

    html = conn |> get(~p"/email/unsubscribe/#{token}") |> html_response(200)
    assert html =~ "Stop the daily emails?"
    # opening the link changed nothing: mail scanners open links
    assert Accounts.get_user!(user.id).email_notify

    # no session, no CSRF token: what a mail app sends
    conn = build_conn() |> post(~p"/email/unsubscribe/#{token}")
    assert redirected_to(conn) == ~p"/email/unsubscribed"
    refute Accounts.get_user!(user.id).email_notify

    assert build_conn() |> get(~p"/email/unsubscribed") |> html_response(200) =~
             "No more daily emails"
  end

  test "a bad token does nothing", %{conn: conn} do
    assert conn |> get(~p"/email/unsubscribe/nope") |> html_response(404) =~ "does not work"
    assert build_conn() |> post(~p"/email/unsubscribe/nope") |> response(404)
  end

  test "Settings turns the daily email off and on", %{conn: conn} do
    user = user_fixture(%{onboarding_completed: true})
    poet_fixture(user)

    {:ok, view, html} =
      conn |> Plug.Test.init_test_session(%{user_id: user.id}) |> live(~p"/settings")

    assert html =~ "Email me each new page"

    view |> form("#email-notify-form", %{"email_notify" => "false"}) |> render_change()
    refute Accounts.get_user!(user.id).email_notify

    view |> form("#email-notify-form", %{"email_notify" => "true"}) |> render_change()
    assert Accounts.get_user!(user.id).email_notify
  end
end
