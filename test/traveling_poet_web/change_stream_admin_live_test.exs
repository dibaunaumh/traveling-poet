defmodule TravelingPoetWeb.ChangeStreamAdminLiveTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.ChangeStream

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  setup do
    on_exit(fn -> :persistent_term.erase({ChangeStream, :enabled?}) end)
    :ok
  end

  test "non-admins are sent home", %{conn: conn} do
    user = user_fixture()
    assert {:error, {:redirect, %{to: "/"}}} = live(sign_in(conn, user), ~p"/admin/change-stream")
  end

  test "renders the empty state and registers an endpoint", %{conn: conn} do
    admin = user_fixture(%{is_admin: true})
    {:ok, view, html} = live(sign_in(conn, admin), ~p"/admin/change-stream")
    assert html =~ "No endpoints registered"
    assert html =~ "worker disabled"

    html =
      view
      |> element("form[phx-submit=register]")
      |> render_submit(%{"url" => "https://agent.example/hook", "auth_token" => "tok"})

    assert html =~ "https://agent.example/hook"
    assert html =~ "Signing secret for"
    [endpoint] = ChangeStream.list_endpoints()
    assert html =~ endpoint.signing_secret
    assert html =~ "badge-success"

    html = render_click(view, "dismiss_secret")
    refute html =~ endpoint.signing_secret
  end

  test "a bad URL is reported, not saved", %{conn: conn} do
    admin = user_fixture(%{is_admin: true})
    {:ok, view, _} = live(sign_in(conn, admin), ~p"/admin/change-stream")

    html =
      view
      |> element("form[phx-submit=register]")
      |> render_submit(%{"url" => "not a url", "auth_token" => "tok"})

    assert html =~ "Could not register"
    assert ChangeStream.list_endpoints() == []
  end

  test "ping, pause, resume and delete", %{conn: conn} do
    Req.Test.set_req_test_to_shared()
    Req.Test.stub(TravelingPoet.ChangeStream, fn conn -> Plug.Conn.send_resp(conn, 200, "ok") end)

    admin = user_fixture(%{is_admin: true})

    {:ok, endpoint} =
      ChangeStream.create_endpoint(%{"url" => "https://agent.example/hook", "auth_token" => "t"})

    {:ok, view, _} = live(sign_in(conn, admin), ~p"/admin/change-stream")

    assert render_click(view, "ping", %{"id" => to_string(endpoint.id)}) =~ "answered 200"
    assert render_click(view, "pause", %{"id" => to_string(endpoint.id)}) =~ "badge-ghost"
    assert render_click(view, "resume", %{"id" => to_string(endpoint.id)}) =~ "badge-success"

    assert render_click(view, "delete", %{"id" => to_string(endpoint.id)}) =~
             "No endpoints registered"

    assert ChangeStream.list_endpoints() == []
  end

  test "failing endpoints get a banner", %{conn: conn} do
    admin = user_fixture(%{is_admin: true})

    {:ok, endpoint} =
      ChangeStream.create_endpoint(%{"url" => "https://down.example/hook", "auth_token" => "t"})

    endpoint
    |> Ecto.Changeset.change(status: "failing", consecutive_failures: 5)
    |> TravelingPoet.Repo.update!()

    {:ok, _view, html} = live(sign_in(conn, admin), ~p"/admin/change-stream")
    assert html =~ "1 endpoint(s) failing"
    assert html =~ "badge-error"
  end
end
