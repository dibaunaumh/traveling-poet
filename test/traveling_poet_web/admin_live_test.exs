defmodule TravelingPoetWeb.AdminLiveTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
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

  test "poets in trouble lead the page and flag their rows", %{conn: conn} do
    admin = user_fixture(%{is_admin: true})
    stuck = agent_user_fixture(%{name: "Dorina M"})
    poet = poet_fixture(stuck, %{name: "Lorcan Byway", status: "error"})
    fine = agent_user_fixture(%{name: "Polina G"})
    poet_fixture(fine, %{name: "Kofi Evenstar"})

    {:ok, view, html} = live(sign_in(conn, admin), ~p"/admin")

    assert html =~ "Needs attention"
    assert html =~ "setup failed"
    attention = view |> element("#needs-attention") |> render()
    assert attention =~ poet.name
    assert attention =~ "Dorina M"
    refute attention =~ "Kofi Evenstar"

    assert view |> element("button[phx-value-f=problems]") |> render() =~ "1"
    view |> element("button[phx-value-f=problems]") |> render_click()
    users = view |> element("#users") |> render()
    assert users =~ "Lorcan Byway"
    refute users =~ "Kofi Evenstar"
  end

  test "readers are listed by name, with the email one hover away", %{conn: conn} do
    admin = user_fixture(%{is_admin: true})
    user_fixture(%{name: "Viola A", email: "c52nfjtsb5@privaterelay.appleid.com"})

    {:ok, view, _html} = live(sign_in(conn, admin), ~p"/admin")

    cell = view |> element("td[title='c52nfjtsb5@privaterelay.appleid.com']") |> render()
    assert cell =~ "Viola A"
    refute cell =~ ">c52nfjtsb5@privaterelay.appleid.com<"
  end

  test "the filters narrow the readers to new, active and low on credits", %{conn: conn} do
    admin = user_fixture(%{is_admin: true, name: "The Admin"})
    old = user_fixture(%{name: "Old Timer"})
    last_month = DateTime.utc_now() |> DateTime.add(-30, :day) |> DateTime.to_naive()

    three_days_ago = DateTime.utc_now() |> DateTime.add(-3, :day) |> DateTime.truncate(:second)

    TravelingPoet.Repo.update_all(
      from(u in TravelingPoet.Accounts.User, where: u.id == ^old.id),
      set: [inserted_at: last_month, last_seen_at: three_days_ago]
    )

    newcomer = user_fixture(%{name: "New Comer"})
    poor = agent_user_fixture(%{name: "Poor Reader", credits: 1})
    poet_fixture(poor, %{name: "Thin Purse"})

    {:ok, view, _html} = live(sign_in(conn, admin), ~p"/admin")

    view |> element("button[phx-value-f=new]") |> render_click()
    html = view |> element("#users") |> render()
    assert html =~ "New Comer"
    refute html =~ "Old Timer"

    view |> element("button[phx-value-f=today]") |> render_click()
    html = view |> element("#users") |> render()
    assert html =~ "The Admin"
    refute html =~ "Old Timer"

    view |> element("button[phx-value-f=week]") |> render_click()
    html = view |> element("#users") |> render()
    assert html =~ "Old Timer"
    refute html =~ "New Comer"

    view |> element("button[phx-value-f=low]") |> render_click()
    html = view |> element("#users") |> render()
    assert html =~ "Poor Reader"
    refute html =~ "New Comer"
    assert newcomer.name == "New Comer"
  end

  test "an ordinary page load stamps the signed-in user", %{conn: conn} do
    user = user_fixture()
    conn |> sign_in(user) |> get(~p"/journal")
    assert Accounts.get_user!(user.id).last_seen_at
  end
end
