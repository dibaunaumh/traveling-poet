defmodule TravelingPoetWeb.NativeAuthTest do
  @moduledoc """
  Google sign-in and Google feature consent for the iOS app: through the
  system sign-in sheet, with the result handed back to the app's web view.
  The sheet and the web view are two cookie jars, so each test keeps two
  conns apart: `sheet` and `app`.
  """
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, Poets, Repo}
  alias TravelingPoetWeb.{AuthController, NativeAuth}

  @app_ua "Mozilla/5.0 (iPhone; CPU iPhone OS 26_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 TravelingPoetiOS/1.0.0"
  @verifier "a-verifier-that-only-the-app-ever-holds-0123456789"

  defp in_app(conn), do: put_req_header(conn, "user-agent", @app_ua)
  defp signed_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  defp google_auth(uid, email, scopes \\ ["email", "profile"]) do
    %Ueberauth.Auth{
      provider: :google,
      uid: uid,
      info: %Ueberauth.Auth.Info{email: email, name: "Udi"},
      credentials: %Ueberauth.Auth.Credentials{
        token: "access-1",
        refresh_token: "refresh-1",
        expires_at: System.os_time(:second) + 3600,
        scopes: scopes
      }
    }
  end

  # Google's answer arriving in a session that holds `session`
  defp callback(session, auth) do
    build_conn()
    |> Plug.Test.init_test_session(session)
    |> Phoenix.ConnTest.fetch_flash()
    |> Plug.Conn.assign(:ueberauth_auth, auth)
    |> AuthController.callback(%{})
  end

  defp app_url(conn) do
    [location] = Plug.Conn.get_resp_header(conn, "location")
    uri = URI.parse(location)
    {uri, URI.decode_query(uri.query || "")}
  end

  describe "signing in" do
    test "the sheet parks the app's challenge and goes on to Google", %{conn: conn} do
      challenge = NativeAuth.challenge(@verifier)
      sheet = get(conn, ~p"/auth/native/start?#{[challenge: challenge]}")

      assert redirected_to(sheet) == "/auth/google"
      assert get_session(sheet, :native_auth) == %{"challenge" => challenge}
    end

    test "a malformed challenge goes straight back to the app as a failure", %{conn: conn} do
      for params <- [%{}, %{"challenge" => "short"}, %{"challenge" => String.duplicate("!", 43)}] do
        {uri, query} = conn |> get(~p"/auth/native/start?#{params}") |> app_url()
        assert uri.scheme == "travelpoet"
        assert query == %{"error" => "failed"}
      end
    end

    test "Google's answer does not sign the sheet in; it sends the app a token",
         %{conn: conn} do
      challenge = NativeAuth.challenge(@verifier)

      sheet =
        callback(
          %{native_auth: %{"challenge" => challenge}},
          google_auth("g-new", "new@example.com")
        )

      {uri, %{"token" => token}} = app_url(sheet)
      assert {uri.scheme, uri.host} == {"travelpoet", "auth"}

      # the account exists, but Safari's session is nobody's
      user = Accounts.get_user_by_google_id("g-new")
      assert user
      assert is_nil(get_session(sheet, :user_id))
      assert is_nil(get_session(sheet, :native_auth))

      # the app trades token + verifier for its own session
      app =
        conn |> in_app() |> post(~p"/auth/native/handoff", %{token: token, verifier: @verifier})

      assert get_session(app, :user_id) == user.id
      assert redirected_to(app) == "/onboarding"
    end

    test "someone with a poet lands on their journal, and the place they typed is carried",
         %{conn: conn} do
      user = user_fixture(%{google_id: "g-old", onboarding_completed: true})
      token = NativeAuth.handoff_token(user.id, NativeAuth.challenge(@verifier))

      app =
        conn |> in_app() |> post(~p"/auth/native/handoff", %{token: token, verifier: @verifier})

      assert redirected_to(app) == "/journal"

      # a new reader who typed a place on the welcome screen first
      newcomer = user_fixture(%{google_id: "g-newcomer"})
      token = NativeAuth.handoff_token(newcomer.id, NativeAuth.challenge(@verifier))

      app =
        build_conn()
        |> in_app()
        |> Plug.Test.init_test_session(%{start_place: "Porto"})
        |> post(~p"/auth/native/handoff", %{token: token, verifier: @verifier})

      assert redirected_to(app) == "/onboarding?place=Porto"
    end

    test "a token is worth nothing without the verifier it was minted for", %{conn: conn} do
      user = user_fixture(%{google_id: "g-victim", onboarding_completed: true})
      token = NativeAuth.handoff_token(user.id, NativeAuth.challenge(@verifier))

      for params <- [
            %{token: token, verifier: "someone-elses-verifier"},
            %{token: token},
            %{token: "garbage", verifier: @verifier},
            %{}
          ] do
        app = build_conn() |> in_app() |> post(~p"/auth/native/handoff", params)
        assert is_nil(get_session(app, :user_id))
        assert redirected_to(app) == "/"
      end

      assert {:ok, _} = NativeAuth.verify_handoff(token, @verifier)
      _ = conn
    end

    test "a token goes stale in a minute" do
      user = user_fixture(%{google_id: "g-slow"})

      stale =
        Phoenix.Token.sign(
          TravelingPoetWeb.Endpoint,
          "native-handoff",
          %{"uid" => user.id, "challenge" => NativeAuth.challenge(@verifier)},
          signed_at: System.system_time(:second) - 120
        )

      assert {:error, :expired} = NativeAuth.verify_handoff(stale, @verifier)
    end

    test "the handoff is CSRF-protected like any other form", %{conn: conn} do
      user = user_fixture(%{google_id: "g-csrf", onboarding_completed: true})
      token = NativeAuth.handoff_token(user.id, NativeAuth.challenge(@verifier))

      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        conn
        |> in_app()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
        |> post(~p"/auth/native/handoff", %{token: token, verifier: @verifier})
      end
    end

    test "Google refusing in the sheet is reported to the app, not flashed at Safari" do
      sheet =
        build_conn()
        |> Plug.Test.init_test_session(%{native_auth: %{"challenge" => "x"}})
        |> Phoenix.ConnTest.fetch_flash()
        |> Plug.Conn.assign(:ueberauth_failure, %Ueberauth.Failure{})
        |> AuthController.callback(%{})

      assert {%URI{scheme: "travelpoet"}, %{"error" => "failed"}} = app_url(sheet)
    end

    test "a browser's sign-in is what it always was" do
      conn = callback(%{}, google_auth("g-browser", "browser@example.com"))
      assert get_session(conn, :user_id) == Accounts.get_user_by_google_id("g-browser").id
      assert redirected_to(conn) == "/onboarding"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Welcome, Udi!"
    end
  end

  describe "connecting Calendar or Drive" do
    setup do
      # put back exactly what was there: other suites rely on the configured value
      before = Application.get_env(:traveling_poet, :calendar_enabled)
      Application.put_env(:traveling_poet, :calendar_enabled, "all")
      on_exit(fn -> Application.put_env(:traveling_poet, :calendar_enabled, before) end)

      user = user_fixture(%{google_id: "g-owner", onboarding_completed: true})
      poet_fixture(user)
      %{user: user}
    end

    test "the app asks for an address to open in the sheet; it names who and what",
         %{conn: conn, user: user} do
      # with the Accept header a web view's fetch() really sends
      app =
        conn
        |> signed_in(user)
        |> in_app()
        |> put_req_header("accept", "*/*")
        |> get(~p"/auth/native/connect_url?feature=calendar")

      assert %{"url" => url} = json_response(app, 200)

      %URI{path: "/auth/native/connect", query: query} = URI.parse(url)
      %{"token" => token} = URI.decode_query(query)

      assert {:ok, %{"uid" => uid, "feature" => "calendar", "pdf" => nil}} =
               NativeAuth.verify_connect(token)

      assert uid == user.id

      assert conn
             |> signed_in(user)
             |> get(~p"/auth/native/connect_url?feature=gmail")
             |> json_response(400)

      # and nobody signed out can ask
      assert build_conn() |> get(~p"/auth/native/connect_url?feature=calendar") |> redirected_to() ==
               "/"
    end

    test "the sheet, which has no session, takes the intent from the token", %{user: user} do
      token = NativeAuth.connect_token(user.id, "calendar")
      sheet = build_conn() |> get(~p"/auth/native/connect?#{[token: token]}")

      assert "/auth/google?" <> query = redirected_to(sheet)
      assert URI.decode_query(query)["scope"] =~ "calendar.events.readonly"
      assert get_session(sheet, :native_auth) == %{"connect" => true}

      assert get_session(sheet, :google_connect) ==
               %{"feature" => "calendar", "pdf" => nil, "user_id" => user.id}

      for bad <- ["garbage", NativeAuth.handoff_token(user.id, "c")] do
        {uri, query} = build_conn() |> get(~p"/auth/native/connect?#{[token: bad]}") |> app_url()
        assert {uri.scheme, query} == {"travelpoet", %{"error" => "failed"}}
      end
    end

    test "the outcome goes back to the app as a code, and Settings says it in words",
         %{conn: conn, user: user} do
      scopes = ["email", "profile", "https://www.googleapis.com/auth/calendar.events.readonly"]
      intent = %{"feature" => "calendar", "pdf" => nil, "user_id" => user.id}
      session = %{native_auth: %{"connect" => true}, google_connect: intent}

      sheet = callback(session, google_auth("g-owner", user.email, scopes))
      {uri, query} = app_url(sheet)

      assert {uri.scheme, uri.host, uri.path} == {"travelpoet", "auth", "/done"}
      assert query == %{"to" => "/settings#trips", "connected" => "calendar:ok"}
      assert is_nil(get_session(sheet, :user_id))
      assert Repo.reload(user).calendar_connected_at

      {:ok, _view, html} =
        live(conn |> signed_in(user) |> in_app(), ~p"/settings?connected=calendar:ok")

      assert html =~ "Google Calendar connected. Looking for trips now."
    end

    test "picking a different Google account in the sheet changes nothing", %{user: user} do
      intent = %{"feature" => "drive", "pdf" => nil, "user_id" => user.id}
      session = %{native_auth: %{"connect" => true}, google_connect: intent}

      {_uri, query} =
        session |> callback(google_auth("g-someone-else", "x@example.com")) |> app_url()

      assert query == %{"to" => "/settings#book", "connected" => "drive:wrong_account"}

      assert {:error, "Please choose the Google account you sign in with."} =
               NativeAuth.connect_notice("drive:wrong_account")

      refute Repo.reload(user).drive_connected_at
    end

    test "a notice code nobody minted says nothing" do
      for junk <- [nil, "", "calendar", "gmail:ok", "calendar:<script>", "drive:nope"] do
        assert is_nil(NativeAuth.connect_notice(junk))
      end
    end

    test "a browser's connect still flashes on the page it came from", %{user: user} do
      intent = %{"feature" => "calendar", "user_id" => user.id}

      conn =
        callback(%{user_id: user.id, google_connect: intent}, google_auth("g-owner", user.email))

      assert redirected_to(conn) == "/settings#trips"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "was not allowed"
    end
  end

  describe "the app's front door" do
    test "signed out: a welcome screen, not the website's pitch", %{conn: conn} do
      html = conn |> in_app() |> get(~p"/") |> html_response(200)

      assert html =~ "Continue with Google"
      assert html =~ ~s(href="/auth/google")
      assert html =~ ~s(action="/start")
      refute html =~ "how-it-works"

      # a browser still gets the home page
      assert conn |> get(~p"/") |> html_response(200) =~ "how-it-works"
    end

    test "a public poet's journal is offered as a sample", %{conn: conn} do
      owner = user_fixture(%{onboarding_completed: true})
      poet = poet_fixture(owner, %{name: "Wren", is_public: true, status: "active"})
      {:ok, poet} = Poets.move_to(poet, %{lat: 41.15, lng: -8.61, place_name: "Porto"})
      published_entry_fixture(poet, %{title: "Fado"})

      html = conn |> in_app() |> get(~p"/") |> html_response(200)
      assert html =~ ~s(href="/p/#{poet.slug}")
      assert html =~ "Wren"
    end

    test "typing a place parks it and comes back to the welcome screen, never to Google",
         %{conn: conn} do
      conn = conn |> in_app() |> get(~p"/start?place=Porto")
      assert redirected_to(conn) == "/"
      assert get_session(conn, :start_place) == "Porto"

      html = conn |> recycle() |> in_app() |> get(~p"/") |> html_response(200)
      assert html =~ "sets out from"
      assert html =~ "Porto"
      refute html =~ ~s(action="/start")
    end

    test "signed in: straight to the journal, or back to onboarding", %{conn: conn} do
      reader = user_fixture(%{onboarding_completed: true})
      assert conn |> signed_in(reader) |> in_app() |> get(~p"/") |> redirected_to() == "/journal"

      newcomer = user_fixture()

      assert build_conn() |> signed_in(newcomer) |> in_app() |> get(~p"/") |> redirected_to() ==
               "/onboarding"
    end
  end
end
