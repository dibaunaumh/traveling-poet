defmodule TravelingPoetWeb.AdminLiveTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.Accounts

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  test "non-admins are sent home", %{conn: conn} do
    user = user_fixture()
    assert {:error, {:redirect, %{to: "/"}}} = live(sign_in(conn, user), ~p"/admin")
  end

  test "shows when each user was last seen, and opening the app counts as being seen", %{
    conn: conn
  } do
    admin = user_fixture(%{is_admin: true})
    quiet = user_fixture(%{email: "quiet@example.com"})
    assert Accounts.get_user!(admin.id).last_seen_at == nil

    {:ok, _view, html} = live(sign_in(conn, admin), ~p"/admin")

    assert html =~ "Last seen"
    # The admin's own visit stamped them...
    assert Accounts.get_user!(admin.id).last_seen_at
    assert html =~ "just now"
    # ...while the user who never opened the app reads "never".
    assert Accounts.get_user!(quiet.id).last_seen_at == nil
    assert html =~ "never"
  end

  test "an ordinary page load stamps the signed-in user", %{conn: conn} do
    user = user_fixture()
    conn |> sign_in(user) |> get(~p"/journal")
    assert Accounts.get_user!(user.id).last_seen_at
  end
end
