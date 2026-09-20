defmodule TravelingPoetWeb.AppReviewReadinessTest do
  @moduledoc """
  What App Store review asks of an app with accounts and AI in it: the reader
  can delete their own account, a reviewer can get in and find something to
  review, nothing goes to an AI model before the reader agreed, and a public
  page can be reported.
  """
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.Accounts.{Purge, User}
  alias TravelingPoet.Repo
  alias TravelingPoetWeb.ReviewLogin

  @app_ua "Mozilla/5.0 (iPhone; CPU iPhone OS 26_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 TravelingPoetiOS/1.0.0"

  defp in_app(conn), do: put_req_header(conn, "user-agent", @app_ua)
  defp signed_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})
  defp consented, do: %{ai_consent_at: DateTime.utc_now(:second)}

  describe "deleting your own account" do
    setup do
      user =
        agent_user_fixture(Map.merge(%{onboarding_completed: true, sprite_url: nil}, consented()))

      poet = poet_fixture(user, %{name: "Wren"})
      published_entry_fixture(poet, %{title: "Fado"})
      %{user: user, poet: poet}
    end

    test "Settings names what goes and asks for the account's email", %{conn: conn, user: user} do
      {:ok, view, _html} = live(signed_in(conn, user), ~p"/settings")

      assert has_element?(view, "#delete-account", "Delete account")
      assert has_element?(view, "#delete-account", "Wren")
      assert has_element?(view, "#delete-account", user.email)
      # it used to be "write to us"
      refute has_element?(view, "#account a[href^='mailto:']")
    end

    test "the wrong address deletes nothing", %{conn: conn, user: user} do
      {:ok, view, _html} = live(signed_in(conn, user), ~p"/settings")

      html =
        view
        |> form("#delete-account-form", %{confirm_email: "someone-else@example.com"})
        |> render_submit()

      assert html =~ "Nothing was deleted"
      assert Repo.get(User, user.id)
    end

    test "the right one takes the account, the poet and the journal, and signs out",
         %{conn: conn, user: user, poet: poet} do
      {:ok, view, _html} = live(signed_in(conn, user), ~p"/settings")

      assert {:error, {:redirect, %{to: "/auth/logout"}}} =
               view
               |> form("#delete-account-form", %{confirm_email: String.upcase(user.email)})
               |> render_submit()

      refute Repo.get(User, user.id)
      refute Repo.get(TravelingPoet.Poets.Poet, poet.id)
      assert Repo.aggregate(TravelingPoet.Journal.Entry, :count) == 0

      # the session now names nobody
      conn = conn |> signed_in(user) |> get(~p"/journal")
      assert redirected_to(conn) == "/"
    end
  end

  describe "deletion withdraws the sign-in grants" do
    setup do
      p8 = :public_key.generate_key({:namedCurve, :secp256r1})
      pem = :public_key.pem_encode([:public_key.pem_entry_encode(:PrivateKeyInfo, p8)])

      for {k, v} <- [
            apple_team_id: "TEAM123456",
            apple_key_id: "KEY1234567",
            apple_private_key: pem,
            apple_bundle_id: "travel.poet.app"
          ],
          do: Application.put_env(:traveling_poet, k, v)

      on_exit(fn ->
        for k <- [:apple_team_id, :apple_key_id, :apple_private_key, :apple_bundle_id],
            do: Application.delete_env(:traveling_poet, k)
      end)

      :ok
    end

    test "Apple is told, signed as us; the account goes either way" do
      test_pid = self()

      Req.Test.stub(TravelingPoet.Apple, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:apple, conn.request_path, URI.decode_query(body)})
        Plug.Conn.send_resp(conn, 200, "")
      end)

      user = user_fixture(%{google_id: nil, apple_id: "001.a", apple_refresh_token: "r.apple"})
      assert {:ok, %{grants: [:apple]}} = Purge.purge(user.id, user.email)

      assert_received {:apple, "/auth/revoke",
                       %{"token" => "r.apple", "client_id" => "travel.poet.app"}}

      refute Repo.get(User, user.id)

      # Apple down: logged, and the account still goes
      Req.Test.stub(TravelingPoet.Apple, fn conn -> Plug.Conn.send_resp(conn, 503, "down") end)
      user = user_fixture(%{google_id: nil, apple_id: "001.b", apple_refresh_token: "r.apple2"})
      assert {:ok, %{grants: []}} = Purge.purge(user.id, user.email)
      refute Repo.get(User, user.id)
    end

    test "an account with no grants asks nobody" do
      user = user_fixture()
      assert {:ok, %{grants: []}} = Purge.purge(user.id, user.email)
    end
  end

  describe "the reviewer's sign-in" do
    @password "a long review password 2026"

    setup do
      ReviewLogin.reset_throttle()

      demo =
        user_fixture(
          Map.merge(%{email: "review@example.com", onboarding_completed: true}, consented())
        )

      on_exit(fn ->
        Application.delete_env(:traveling_poet, :review_login_email)
        Application.delete_env(:traveling_poet, :review_login_password_hash)
        ReviewLogin.reset_throttle()
      end)

      %{demo: demo}
    end

    defp enable do
      Application.put_env(:traveling_poet, :review_login_email, "review@example.com")

      Application.put_env(
        :traveling_poet,
        :review_login_password_hash,
        ReviewLogin.hash_password(@password)
      )
    end

    test "does not exist until both secrets are set", %{conn: conn} do
      assert conn |> get(~p"/auth/review") |> html_response(404)

      assert conn
             |> post(~p"/auth/review", %{email: "review@example.com", password: @password})
             |> html_response(404)

      Application.put_env(:traveling_poet, :review_login_email, "review@example.com")
      assert conn |> get(~p"/auth/review") |> html_response(404)

      refute conn |> in_app() |> get(~p"/") |> html_response(200) =~ "reviewer-sign-in"
    end

    test "opens the demo account, and only with its email and password", %{conn: conn, demo: demo} do
      enable()
      assert conn |> get(~p"/auth/review") |> html_response(200) =~ "Reviewer sign-in"
      assert conn |> in_app() |> get(~p"/") |> html_response(200) =~ ~s(id="reviewer-sign-in")

      ok = post(conn, ~p"/auth/review", %{email: "Review@Example.com", password: @password})
      assert get_session(ok, :user_id) == demo.id
      assert redirected_to(ok) == "/journal"

      for {email, password} <- [
            {"review@example.com", "the wrong password!!"},
            {"someone@example.com", @password},
            {"", ""}
          ] do
        bad = post(build_conn(), ~p"/auth/review", %{email: email, password: password})
        assert html_response(bad, 401) =~ "do not match"
        assert is_nil(get_session(bad, :user_id))
      end
    end

    test "cannot open any other account, even with the right password", %{conn: conn} do
      enable()
      user_fixture(%{email: "udi@example.com", onboarding_completed: true})

      conn = post(conn, ~p"/auth/review", %{email: "udi@example.com", password: @password})
      assert html_response(conn, 401)
      assert is_nil(get_session(conn, :user_id))
    end

    test "gives up listening after too many wrong guesses", %{conn: conn} do
      enable()

      for _ <- 1..8 do
        assert conn
               |> post(~p"/auth/review", %{
                 email: "review@example.com",
                 password: "wrong wrong wrong"
               })
               |> html_response(401)
      end

      locked = post(conn, ~p"/auth/review", %{email: "review@example.com", password: @password})
      assert html_response(locked, 429) =~ "Too many attempts"
      assert is_nil(get_session(locked, :user_id))
    end

    test "a hash is salted, and a short password is refused outright" do
      assert ReviewLogin.hash_password(@password) != ReviewLogin.hash_password(@password)
      assert_raise FunctionClauseError, fn -> ReviewLogin.hash_password("short") end
    end
  end

  describe "consent to third-party AI, in the app" do
    setup do
      user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
      poet_fixture(user)
      %{user: user}
    end

    test "every signed-in page leads to it until the reader has agreed", %{conn: conn, user: user} do
      for path <- [~p"/journal", ~p"/guide", ~p"/settings", ~p"/onboarding"] do
        assert {:error, {:redirect, %{to: "/ai-consent"}}} =
                 live(conn |> signed_in(user) |> in_app(), path)
      end

      html = conn |> signed_in(user) |> in_app() |> get(~p"/ai-consent") |> html_response(200)
      assert html =~ "OpenRouter"
      assert html =~ "I agree"
      assert html =~ ~s(href="/auth/logout")
    end

    test "agreeing is recorded once and opens the app", %{conn: conn, user: user} do
      conn = conn |> signed_in(user) |> in_app() |> post(~p"/ai-consent")
      assert redirected_to(conn) == "/journal"

      agreed_at = Repo.reload(user).ai_consent_at
      assert %DateTime{} = agreed_at

      {:ok, _view, _html} = live(build_conn() |> signed_in(user) |> in_app(), ~p"/journal")

      # agreeing again does not move the date; the page itself has nothing left to ask
      build_conn() |> signed_in(user) |> in_app() |> post(~p"/ai-consent")
      assert Repo.reload(user).ai_consent_at == agreed_at

      assert build_conn()
             |> signed_in(user)
             |> in_app()
             |> get(~p"/ai-consent")
             |> redirected_to() == "/journal"
    end

    test "someone still onboarding goes on to onboarding", %{conn: conn} do
      newcomer = user_fixture()
      conn = conn |> signed_in(newcomer) |> in_app() |> post(~p"/ai-consent")
      assert redirected_to(conn) == "/onboarding"
    end

    test "the website never asks", %{conn: conn, user: user} do
      {:ok, _view, _html} = live(signed_in(conn, user), ~p"/journal")
      assert conn |> signed_in(user) |> get(~p"/ai-consent") |> redirected_to() == "/journal"
      assert is_nil(Repo.reload(user).ai_consent_at)
    end

    test "signed out, there is nothing to agree to", %{conn: conn} do
      assert conn |> in_app() |> get(~p"/ai-consent") |> redirected_to() == "/"
    end
  end

  test "a public journal can be reported from the page, naming the page", %{conn: conn} do
    owner = user_fixture(%{onboarding_completed: true})
    poet = poet_fixture(owner, %{name: "Wren", is_public: true, status: "active"})
    published_entry_fixture(poet, %{title: "Fado", entry_date: ~D[2026-03-05]})

    {:ok, view, _html} = live(conn, ~p"/p/#{poet.slug}")

    href =
      view
      |> element("#report-journal")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("href")
      |> hd()

    assert "mailto:" <> _ = href
    assert URI.decode(href) =~ "Report: http"
    assert URI.decode(href) =~ "/p/#{poet.slug}/2026-03-05"
  end

  test "the legal pages say Apple, and say deletion is yours to do", %{conn: conn} do
    assert conn |> get(~p"/terms") |> html_response(200) =~ "Sign in with Google or with Apple"
    privacy = conn |> get(~p"/privacy") |> html_response(200)
    assert privacy =~ "Sign in with Apple"
    assert privacy =~ "under Account"
    assert conn |> get(~p"/support") |> html_response(200) =~ "Delete account"
  end
end
