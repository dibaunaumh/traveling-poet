defmodule TravelingPoetWeb.CreditsControllerTest do
  use TravelingPoetWeb.ConnCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, Credits}
  alias TravelingPoet.Payments.Mock

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: Plug.Test.init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "checkout sends the buyer to the mock pay page", %{conn: conn} do
    conn = post(conn, ~p"/credits/checkout", %{"pack" => "p50"})
    assert "/credits/mock-checkout?token=" <> _ = redirected_to(conn)

    conn = get(conn, redirected_to(conn))
    html = html_response(conn, 200)
    assert html =~ "MOCK CHECKOUT"
    assert html =~ "50 credits"
    assert html =~ "$20.00"
  end

  test "unknown pack bounces back to settings", %{conn: conn} do
    conn = post(conn, ~p"/credits/checkout", %{"pack" => "bogus"})
    assert redirected_to(conn) == "/settings"
  end

  test "mock confirm credits the pack exactly once", %{conn: conn, user: user} do
    token = Mock.sign(user.id, "p10")

    conn1 = post(conn, ~p"/credits/mock-checkout/confirm", %{"token" => token})
    assert redirected_to(conn1) == "/settings?purchased=1"
    assert Credits.balance(Accounts.get_user!(user.id)) == 10_000

    _conn2 = post(conn, ~p"/credits/mock-checkout/confirm", %{"token" => token})
    assert Credits.balance(Accounts.get_user!(user.id)) == 10_000
  end

  test "a token for another user is rejected", %{conn: conn, user: user} do
    other = user_fixture()

    conn =
      post(conn, ~p"/credits/mock-checkout/confirm", %{"token" => Mock.sign(other.id, "p10")})

    assert redirected_to(conn) == "/settings"
    assert Credits.balance(Accounts.get_user!(user.id)) == 0
    assert Credits.balance(Accounts.get_user!(other.id)) == 0
  end

  test "requires sign-in", %{conn: _} do
    conn = post(build_conn(), ~p"/credits/checkout", %{"pack" => "p10"})
    assert redirected_to(conn) == "/"
  end
end
