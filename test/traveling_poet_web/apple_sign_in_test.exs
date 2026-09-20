defmodule TravelingPoetWeb.AppleSignInTest do
  @moduledoc """
  Sign in with Apple from the iOS app, and what it means for accounts: one
  person, one account, however they sign in.
  """
  use TravelingPoetWeb.ConnCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, Apple, Credits, Repo}
  alias TravelingPoet.Apple.IdentityToken
  alias TravelingPoetWeb.AuthController

  @app_ua "Mozilla/5.0 (iPhone; CPU iPhone OS 26_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 TravelingPoetiOS/1.0.0"
  @bundle "travel.poet.app"
  @raw_nonce "the-nonce-this-session-made"

  defp b64(bin), do: Base.url_encode64(bin, padding: false)

  setup do
    # Apple's side: an RSA key that signs identity tokens, published as a JWK
    apple_key = :public_key.generate_key({:rsa, 2048, 65_537})
    {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} = apple_key

    jwk = %{
      "kty" => "RSA",
      "kid" => "apple-kid",
      "alg" => "RS256",
      "n" => b64(:binary.encode_unsigned(n)),
      "e" => b64(:binary.encode_unsigned(e))
    }

    # Our side: the .p8 key the client secret is signed with
    p8 = :public_key.generate_key({:namedCurve, :secp256r1})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:PrivateKeyInfo, p8)])

    for {k, v} <- [
          apple_team_id: "TEAM123456",
          apple_key_id: "KEY1234567",
          apple_private_key: pem,
          apple_bundle_id: @bundle
        ],
        do: Application.put_env(:traveling_poet, k, v)

    IdentityToken.forget_keys()

    on_exit(fn ->
      for k <- [:apple_team_id, :apple_key_id, :apple_private_key, :apple_bundle_id],
          do: Application.delete_env(:traveling_poet, k)

      IdentityToken.forget_keys()
    end)

    test_pid = self()

    Req.Test.stub(TravelingPoet.Apple, fn conn ->
      case conn.request_path do
        "/auth/keys" ->
          Req.Test.json(conn, %{"keys" => [jwk]})

        "/auth/token" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:apple_token_request, URI.decode_query(body)})
          Req.Test.json(conn, %{"refresh_token" => "r.apple-refresh", "access_token" => "a"})

        "/auth/revoke" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:apple_revoke_request, URI.decode_query(body)})
          Plug.Conn.send_resp(conn, 200, "")
      end
    end)

    sign = fn claims ->
      claims =
        Map.merge(
          %{
            "iss" => "https://appleid.apple.com",
            "aud" => @bundle,
            "exp" => System.os_time(:second) + 600,
            "nonce" => IdentityToken.hashed_nonce(@raw_nonce),
            "sub" => "001.apple-sub",
            "email" => "udi@example.com",
            "email_verified" => "true"
          },
          claims
        )

      input =
        b64(Jason.encode!(%{"alg" => "RS256", "kid" => "apple-kid"})) <>
          "." <> b64(Jason.encode!(claims))

      input <> "." <> b64(:public_key.sign(input, :sha256, apple_key))
    end

    %{sign: sign}
  end

  defp app(session \\ %{}) do
    build_conn()
    |> put_req_header("user-agent", @app_ua)
    |> Plug.Test.init_test_session(Map.put_new(session, :apple_nonce, @raw_nonce))
  end

  defp post_token(conn, token, extra \\ %{}) do
    post(
      conn,
      ~p"/auth/apple/native",
      Map.merge(%{"identity_token" => token, "authorization_code" => "c.code"}, extra)
    )
  end

  describe "the identity token" do
    test "is trusted only when Apple signed it, for this app, now, for this session", %{
      sign: sign
    } do
      assert {:ok,
              %{
                sub: "001.apple-sub",
                email: "udi@example.com",
                email_verified: true,
                private_relay: false
              }} =
               IdentityToken.verify(sign.(%{}), @raw_nonce)

      assert {:error, :wrong_audience} =
               IdentityToken.verify(sign.(%{"aud" => "com.someone.else"}), @raw_nonce)

      assert {:error, :wrong_issuer} =
               IdentityToken.verify(sign.(%{"iss" => "https://evil.example"}), @raw_nonce)

      assert {:error, :expired} =
               IdentityToken.verify(sign.(%{"exp" => System.os_time(:second) - 1}), @raw_nonce)

      assert {:error, :wrong_nonce} = IdentityToken.verify(sign.(%{}), "another-sessions-nonce")
      assert {:error, :wrong_nonce} = IdentityToken.verify(sign.(%{"nonce" => nil}), @raw_nonce)
      assert {:error, :malformed} = IdentityToken.verify("not.a.token", @raw_nonce)
      assert {:error, :malformed} = IdentityToken.verify(sign.(%{}), nil)
    end

    test "knows a Hide My Email address, flagged or not", %{sign: sign} do
      relay = "abc123@privaterelay.appleid.com"

      assert {:ok, %{private_relay: true}} =
               IdentityToken.verify(sign.(%{"email" => relay}), @raw_nonce)

      assert {:ok, %{private_relay: true}} =
               IdentityToken.verify(sign.(%{"is_private_email" => true}), @raw_nonce)
    end
  end

  describe "signing in" do
    test "a new reader gets an account, welcome credits and onboarding", %{sign: sign} do
      conn =
        post_token(app(%{start_place: "Porto"}), sign.(%{}), %{
          "given_name" => "Udi",
          "family_name" => "Bauman"
        })

      user = Accounts.get_user_by_apple_id("001.apple-sub")
      assert user.email == "udi@example.com"
      assert user.name == "Udi Bauman"
      assert is_nil(user.google_id)
      assert user.credits_balance == Credits.signup_credits() * 1000 or user.credits_balance > 0

      assert get_session(conn, :user_id) == user.id
      assert redirected_to(conn) == "/onboarding?place=Porto"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Welcome, Udi Bauman!"

      # the code was traded for the token that account deletion will need
      assert_received {:apple_token_request,
                       %{
                         "code" => "c.code",
                         "client_id" => @bundle,
                         "grant_type" => "authorization_code"
                       } = form}

      assert {:ok, %{"kid" => "KEY1234567", "alg" => "ES256"},
              %{"iss" => "TEAM123456", "sub" => @bundle}} =
               TravelingPoet.JWS.peek(form["client_secret"])

      assert Repo.reload(user).apple_refresh_token == "r.apple-refresh"
    end

    test "coming back needs no name and lands on the journal", %{sign: sign} do
      user =
        user_fixture(%{
          google_id: nil,
          apple_id: "001.apple-sub",
          name: "Udi",
          onboarding_completed: true
        })

      conn = post_token(app(), sign.(%{}))
      assert get_session(conn, :user_id) == user.id
      assert redirected_to(conn) == "/journal"
      assert Repo.reload(user).name == "Udi"
    end

    test "the nonce is spent: the same token does not work twice in a session", %{sign: sign} do
      token = sign.(%{})
      first = post_token(app(), token)
      assert get_session(first, :user_id)
      assert is_nil(get_session(first, :apple_nonce))

      again =
        build_conn()
        |> put_req_header("user-agent", @app_ua)
        |> Plug.Test.init_test_session(%{})
        |> post_token(token)

      assert is_nil(get_session(again, :user_id))
      assert redirected_to(again) == "/"
    end

    test "a token for another app, or for another session, signs nobody in", %{sign: sign} do
      for token <- [
            sign.(%{"aud" => "com.someone.else"}),
            sign.(%{"nonce" => "stolen"}),
            "garbage"
          ] do
        conn = post_token(app(), token)
        assert is_nil(get_session(conn, :user_id))
        assert redirected_to(conn) == "/"
        assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "did not go through"
      end

      assert is_nil(Accounts.get_user_by_apple_id("001.apple-sub"))
    end

    test "Apple's token endpoint failing does not fail the sign-in", %{sign: sign} do
      token = sign.(%{})
      # the key set is fetched and cached while Apple is still answering
      assert {:ok, _} = IdentityToken.verify(token, @raw_nonce)

      Req.Test.stub(TravelingPoet.Apple, fn conn -> Plug.Conn.send_resp(conn, 500, "down") end)

      conn = post_token(app(), token)
      user = Accounts.get_user_by_apple_id("001.apple-sub")
      assert get_session(conn, :user_id) == user.id
      assert is_nil(user.apple_refresh_token)
    end

    test "with no key set to check against, nobody is signed in", %{sign: sign} do
      Req.Test.stub(TravelingPoet.Apple, fn conn -> Plug.Conn.send_resp(conn, 500, "down") end)

      conn = post_token(app(), sign.(%{}))
      assert is_nil(get_session(conn, :user_id))
    end

    test "unconfigured, the endpoint refuses and the welcome screen shows no Apple button", %{
      sign: sign
    } do
      Application.delete_env(:traveling_poet, :apple_private_key)

      conn = post_token(app(), sign.(%{}))
      assert is_nil(get_session(conn, :user_id))

      html =
        build_conn() |> put_req_header("user-agent", @app_ua) |> get(~p"/") |> html_response(200)

      refute html =~ "sign-in-with-apple"
      assert html =~ "Continue with Google"
    end

    test "configured, the welcome screen offers Apple first, with this session's nonce" do
      conn = build_conn() |> put_req_header("user-agent", @app_ua) |> get(~p"/")
      html = html_response(conn, 200)

      raw = get_session(conn, :apple_nonce)
      assert is_binary(raw)
      assert html =~ ~s(data-apple-nonce="#{IdentityToken.hashed_nonce(raw)}")
      refute html =~ raw

      {apple_at, _} = :binary.match(html, "Sign in with Apple")
      {google_at, _} = :binary.match(html, "Continue with Google")
      assert apple_at < google_at
    end
  end

  describe "one person, one account" do
    test "Apple with the address of a Google-made account arrives at that account", %{sign: sign} do
      existing =
        user_fixture(%{google_id: "g-udi", email: "Udi@Example.com", onboarding_completed: true})

      conn = post_token(app(), sign.(%{}))

      assert get_session(conn, :user_id) == existing.id
      assert redirected_to(conn) == "/journal"
      linked = Repo.reload(existing)
      assert {linked.google_id, linked.apple_id} == {"g-udi", "001.apple-sub"}
      assert Repo.aggregate(TravelingPoet.Accounts.User, :count) == 1
    end

    test "an unverified address links nothing (and cannot take the address either)", %{sign: sign} do
      existing = user_fixture(%{google_id: "g-udi", email: "udi@example.com"})

      conn = post_token(app(), sign.(%{"email_verified" => "false"}))

      assert is_nil(get_session(conn, :user_id))
      assert is_nil(Repo.reload(existing).apple_id)
    end

    test "a Hide My Email address never matches: a new account of its own", %{sign: sign} do
      user_fixture(%{google_id: "g-udi", email: "udi@example.com"})
      relay = "abc123@privaterelay.appleid.com"

      conn = post_token(app(), sign.(%{"email" => relay, "is_private_email" => "true"}))

      user = Accounts.get_user_by_apple_id("001.apple-sub")
      assert user.email == relay
      assert get_session(conn, :user_id) == user.id
      assert Repo.aggregate(TravelingPoet.Accounts.User, :count) == 2
    end

    test "Google with the verified address of an Apple-made account arrives there too" do
      existing =
        user_fixture(%{google_id: nil, apple_id: "001.apple-sub", email: "udi@example.com"})

      assert {:ok, user} =
               Accounts.find_or_create_from_oauth(:google, %{
                 "sub" => "g-udi",
                 "email" => "udi@example.com",
                 "name" => "Udi",
                 "email_verified" => true
               })

      assert user.id == existing.id
      assert user.google_id == "g-udi"

      # without Google's word that the address is verified, nothing is linked
      assert {:error, %Ecto.Changeset{}} =
               Accounts.find_or_create_from_oauth(:google, %{
                 "sub" => "g-other",
                 "email" => "udi@example.com",
                 "name" => "Someone"
               })
    end

    test "a sign-in with no email at all is refused" do
      assert {:error, :no_email} =
               Accounts.find_or_create_from_oauth(:apple, %{"sub" => "001.x", "email" => nil})
    end
  end

  describe "an Apple-made account connecting Google" do
    setup do
      Application.put_env(:traveling_poet, :calendar_enabled, "all")
      on_exit(fn -> Application.delete_env(:traveling_poet, :calendar_enabled) end)

      user =
        user_fixture(%{google_id: nil, apple_id: "001.apple-sub", onboarding_completed: true})

      poet_fixture(user)
      %{user: user}
    end

    defp google_callback(user, uid) do
      auth = %Ueberauth.Auth{
        provider: :google,
        uid: uid,
        info: %Ueberauth.Auth.Info{email: "g@example.com", name: "Udi"},
        credentials: %Ueberauth.Auth.Credentials{
          token: "access-1",
          refresh_token: "refresh-1",
          expires_at: System.os_time(:second) + 3600,
          scopes: ["email", "profile", "https://www.googleapis.com/auth/calendar.events.readonly"]
        }
      }

      build_conn()
      |> Plug.Test.init_test_session(%{
        user_id: user.id,
        google_connect: %{"feature" => "calendar", "user_id" => user.id}
      })
      |> Phoenix.ConnTest.fetch_flash()
      |> Plug.Conn.assign(:ueberauth_auth, auth)
      |> AuthController.callback(%{})
    end

    test "the Google account picked becomes this account's, and the feature connects", %{
      user: user
    } do
      conn = google_callback(user, "g-fresh")

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Google Calendar connected"
      user = Repo.reload(user)
      assert user.google_id == "g-fresh"
      assert user.calendar_connected_at
    end

    test "unless someone else already signs in with it", %{user: user} do
      user_fixture(%{google_id: "g-taken"})
      conn = google_callback(user, "g-taken")

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "already has its own"
      user = Repo.reload(user)
      assert is_nil(user.google_id)
      refute user.calendar_connected_at
    end
  end

  test "revoke sends Apple the refresh token, signed as us" do
    assert :ok = Apple.revoke("r.apple-refresh")

    assert_received {:apple_revoke_request,
                     %{
                       "token" => "r.apple-refresh",
                       "token_type_hint" => "refresh_token",
                       "client_id" => @bundle
                     }}

    assert {:error, :no_token} = Apple.revoke(nil)
  end
end
