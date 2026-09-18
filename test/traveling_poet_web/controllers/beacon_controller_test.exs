defmodule TravelingPoetWeb.BeaconControllerTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Ecto.Query

  alias TravelingPoet.Analytics
  alias TravelingPoet.Analytics.VisitEvent
  alias TravelingPoet.Repo
  alias TravelingPoetWeb.AuthController

  @ua "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) Safari/604.1"

  defp beacon(conn, body, ua \\ @ua) do
    conn
    |> put_req_header("user-agent", ua)
    |> put_req_header("content-type", "text/plain;charset=UTF-8")
    |> post(~p"/e", body)
  end

  test "stores a page view under a server-computed visitor id", %{conn: conn} do
    body =
      Jason.encode!(%{
        n: "pageview",
        p: "/",
        r: "news.ycombinator.com",
        us: "hn",
        m: true,
        visitor: "forged"
      })

    assert beacon(conn, body).status == 204

    assert [event] = Repo.all(VisitEvent)
    assert event.name == "pageview"
    assert event.path == "/"
    assert event.referrer_host == "news.ycombinator.com"
    assert event.utm_source == "hn"
    assert event.viewport == "mobile"
    assert event.visitor == Analytics.visitor_id("127.0.0.1", @ua, Date.utc_today())
  end

  test "stores engage and click reports", %{conn: conn} do
    beacon(conn, Jason.encode!(%{n: "engage", p: "/", d: 12_345.6, s: 70}))
    beacon(build_conn(), Jason.encode!(%{n: "click", p: "/", t: "cta-closing"}))

    assert [%{name: "engage", duration_ms: 12_346, scroll_pct: 70}] =
             Repo.all(from e in VisitEvent, where: e.name == "engage")

    assert [%{target: "cta-closing"}] = Repo.all(from e in VisitEvent, where: e.name == "click")
  end

  test "answers 204 and stores nothing for garbage, server-only names, oversize bodies and bots",
       %{conn: conn} do
    assert beacon(conn, "not json").status == 204
    assert beacon(build_conn(), Jason.encode!(%{n: "signup", p: "/"})).status == 204

    assert beacon(build_conn(), Jason.encode!(%{n: "pageview", p: String.duplicate("x", 3_000)})).status ==
             204

    assert beacon(build_conn(), Jason.encode!(%{n: "pageview", p: "/"}), "Googlebot/2.1").status ==
             204

    assert Repo.aggregate(VisitEvent, :count) == 0
  end

  describe "sign-in" do
    defp callback(uid) do
      auth = %Ueberauth.Auth{
        provider: :google,
        uid: uid,
        info: %Ueberauth.Auth.Info{email: "#{uid}@example.com", name: "Visitor"}
      }

      build_conn()
      |> put_req_header("user-agent", @ua)
      |> Plug.Test.init_test_session(%{})
      |> Phoenix.ConnTest.fetch_flash()
      |> Plug.Conn.assign(:ueberauth_auth, auth)
      |> AuthController.callback(%{})
    end

    test "a new account records a signup joined to the day's visitor, a returning one a login" do
      callback("google-new")
      visitor = Analytics.visitor_id("127.0.0.1", @ua, Date.utc_today())

      assert [%{name: "signup", visitor: ^visitor, user_id: user_id}] = Repo.all(VisitEvent)
      assert Repo.get!(TravelingPoet.Accounts.User, user_id).google_id == "google-new"

      callback("google-new")

      assert [_, %{name: "login", user_id: ^user_id}] =
               Repo.all(from e in VisitEvent, order_by: e.id)
    end

    test "purging the user removes their sign-in rows" do
      callback("google-gone")
      [%{user_id: user_id}] = Repo.all(VisitEvent)
      user = Repo.get!(TravelingPoet.Accounts.User, user_id)

      TravelingPoet.Accounts.Purge.purge_by_email(user.email)
      assert Repo.aggregate(VisitEvent, :count) == 0
    end
  end
end
