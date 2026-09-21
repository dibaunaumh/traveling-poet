defmodule TravelingPoet.ApnsTest do
  @moduledoc """
  Notifications to the iOS app. Apple's push service is a `Req.Test` stub;
  the key that signs the provider token is made on the spot.
  """
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.Apns.Device
  alias TravelingPoet.{Apns, JWS, Repo, WebPush}

  @app_ua "Mozilla/5.0 (iPhone; CPU iPhone OS 26_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 TravelingPoetiOS/1.0.0"
  @token String.duplicate("ab12", 16)
  @other_token String.duplicate("cd34", 16)

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

    Apns.forget_provider_token()

    on_exit(fn ->
      for k <- [:apple_team_id, :apple_key_id, :apple_private_key, :apple_bundle_id],
          do: Application.delete_env(:traveling_poet, k)

      Apns.forget_provider_token()
    end)

    user =
      agent_user_fixture(%{
        onboarding_completed: true,
        sprite_url: nil,
        ai_consent_at: DateTime.utc_now(:second)
      })

    poet = poet_fixture(user, %{name: "Wren"})
    %{user: user, poet: poet}
  end

  # Apple answering `status` to everything, and telling the test what it was sent
  defp apple(status, body \\ %{}) do
    test_pid = self()

    Req.Test.stub(TravelingPoet.Apns, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:apns, conn, Jason.decode!(raw)})
      conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
    end)
  end

  defp header(conn, name), do: conn |> Plug.Conn.get_req_header(name) |> List.first()

  describe "a published entry" do
    test "reaches the app with the same words a browser gets, and where a tap leads",
         %{user: user, poet: poet} do
      apple(200)
      {:ok, _} = Apns.register(user, @token, "sandbox")
      entry = published_entry_fixture(poet, %{title: "Fado", teaser: "Twelve strings, one ache."})

      assert {1, 0} = WebPush.notify_entry(poet.id, entry.id)

      assert_received {:apns, conn, body}
      assert conn.host == "api.sandbox.push.apple.com"
      assert conn.request_path == "/3/device/#{@token}"
      assert header(conn, "apns-topic") == "travel.poet.app"
      assert header(conn, "apns-push-type") == "alert"
      assert header(conn, "apns-collapse-id") == "entry-#{entry.id}"

      expected = WebPush.entry_payload(poet, entry, TravelingPoet.Journal.journey_day(entry))

      assert body["aps"]["alert"] == %{
               "title" => expected.title,
               "body" => "Twelve strings, one ache."
             }

      assert body["aps"]["thread-id"] == "entry"
      assert body["url"] == expected.url

      "bearer " <> jwt = header(conn, "authorization")

      assert {:ok, %{"alg" => "ES256", "kid" => "KEY1234567"}, %{"iss" => "TEAM123456"}} =
               JWS.peek(jwt)

      assert %Device{last_sent_at: %DateTime{}, last_error: nil} =
               Repo.get_by!(Device, token: @token)
    end

    test "a production build's token goes to the production host", %{user: user, poet: poet} do
      apple(200)
      {:ok, _} = Apns.register(user, @token, "production")
      entry = published_entry_fixture(poet)

      WebPush.notify_entry(poet.id, entry.id)
      assert_received {:apns, %{host: "api.push.apple.com"}, _}
    end

    test "costs nothing when nobody turned notifications on", %{poet: poet} do
      Req.Test.stub(TravelingPoet.Apns, fn _conn -> flunk("nobody to notify") end)
      entry = published_entry_fixture(poet)
      assert {0, 0} = WebPush.notify_entry(poet.id, entry.id)
    end
  end

  describe "a token Apple no longer knows" do
    test "is forgotten: 410, or a 400 that says the token is bad", %{user: user, poet: poet} do
      entry = published_entry_fixture(poet)

      for {status, reason} <- [
            {410, "Unregistered"},
            {400, "BadDeviceToken"},
            {400, "DeviceTokenNotForTopic"}
          ] do
        apple(status, %{"reason" => reason})
        {:ok, _} = Apns.register(user, @token, "production")

        assert {0, 1} = WebPush.notify_entry(poet.id, entry.id)
        refute Repo.get_by(Device, token: @token)
      end
    end

    test "any other refusal keeps the device and writes down why", %{user: user, poet: poet} do
      apple(429, %{"reason" => "TooManyRequests"})
      {:ok, _} = Apns.register(user, @token, "production")
      entry = published_entry_fixture(poet)

      assert {0, 0} = WebPush.notify_entry(poet.id, entry.id)
      assert %Device{last_error: "429 TooManyRequests"} = Repo.get_by!(Device, token: @token)
    end
  end

  describe "the provider token" do
    test "is kept for fifty minutes, because Apple throttles senders who mint them freely" do
      now = System.os_time(:second)
      first = Apns.provider_token(now)

      assert Apns.provider_token(now + 49 * 60) == first
      refute Apns.provider_token(now + 51 * 60) == first
    end

    test "is thrown away when Apple says it expired", %{user: user, poet: poet} do
      stale = Apns.provider_token()
      apple(403, %{"reason" => "ExpiredProviderToken"})
      {:ok, _} = Apns.register(user, @token, "production")

      WebPush.notify_entry(poet.id, published_entry_fixture(poet).id)

      # not the device's fault: it stays, and the next send signs afresh
      assert Repo.get_by(Device, token: @token)
      refute Apns.provider_token(System.os_time(:second) + 1) == stale
    end
  end

  describe "devices" do
    test "one phone is one row, and follows whoever signs in on it", %{user: user} do
      other = user_fixture()
      {:ok, _} = Apns.register(user, @token, "sandbox")
      {:ok, _} = Apns.register(other, String.upcase(@token), "production")

      assert [%Device{user_id: uid, environment: "production"}] = Repo.all(Device)
      assert uid == other.id
      assert Apns.count(user) == 0
    end

    test "only a hex token and a known environment are kept", %{user: user} do
      assert {:error, _} = Apns.register(user, "not a token", "sandbox")
      assert {:error, _} = Apns.register(user, @token, "staging")
      assert {:error, :invalid} = Apns.register(user, nil, "sandbox")
    end

    test "go with the account", %{user: user} do
      {:ok, _} = Apns.register(user, @token, "sandbox")
      {:ok, _} = TravelingPoet.Accounts.Purge.purge(user.id, user.email)
      assert Repo.aggregate(Device, :count) == 0
    end

    test "unconfigured, nobody is listed and nothing is sent", %{user: user, poet: poet} do
      {:ok, _} = Apns.register(user, @token, "sandbox")
      Application.delete_env(:traveling_poet, :apple_private_key)
      Req.Test.stub(TravelingPoet.Apns, fn _conn -> flunk("not configured") end)

      assert Apns.list_devices(user.id) == []
      assert {0, 0} = WebPush.notify_entry(poet.id, published_entry_fixture(poet).id)
    end
  end

  describe "turning notifications on, in the app" do
    defp settings(conn, user) do
      conn =
        conn
        |> Plug.Test.init_test_session(%{user_id: user.id})
        |> put_req_header("user-agent", @app_ua)

      {:ok, view, _html} = live(conn, ~p"/settings")
      view
    end

    test "the same switch, over Apple's push service", %{conn: conn, user: user} do
      view = settings(conn, user)

      html =
        render_hook(element(view, "#push-settings"), "push_state", %{
          "state" => "available",
          "dismissed" => false
        })

      assert html =~ "Turn on"

      device = %{"token" => @token, "environment" => "sandbox"}

      html =
        render_hook(element(view, "#push-settings"), "push_subscribed", %{"device" => device})

      assert html =~ "Turn off"
      assert html =~ "1 device is subscribed"
      assert Apns.registered?(user, @token)

      html =
        render_hook(element(view, "#push-settings"), "push_unsubscribed", %{
          "device_token" => @token
        })

      assert html =~ "Turn on"
      refute Apns.registered?(user, @token)
    end

    test "a phone that already has permission heals its row on every visit", %{
      conn: conn,
      user: user
    } do
      view = settings(conn, user)
      device = %{"token" => @other_token, "environment" => "production"}

      render_hook(element(view, "#push-settings"), "push_state", %{
        "state" => "subscribed",
        "device" => device
      })

      assert Apns.registered?(user, @other_token)
    end

    test "speaks of the Settings app, not of a browser or a site", %{conn: conn, user: user} do
      view = settings(conn, user)
      block = fn -> view |> element("#push-settings") |> render() end

      render_hook(element(view, "#push-settings"), "push_state", %{"state" => "denied"})
      assert block.() =~ "Settings app"
      refute block.() =~ "browser"
      refute block.() =~ "this site"

      render_hook(element(view, "#push-settings"), "push_state", %{"state" => "unsupported"})
      assert block.() =~ "not available on this device"
      refute block.() =~ "browser"
    end

    test "a junk token turns nothing on", %{conn: conn, user: user} do
      view = settings(conn, user)

      html =
        render_hook(element(view, "#push-settings"), "push_subscribed", %{
          "device" => %{"token" => "<script>"}
        })

      assert html =~ "Could not turn notifications on"
      assert Apns.count(user) == 0
    end
  end

  test "signing out of the app stops this phone's notifications, and only this phone's", %{
    conn: conn,
    user: user
  } do
    {:ok, _} = Apns.register(user, @token, "sandbox")
    {:ok, _} = Apns.register(user, @other_token, "sandbox")

    conn =
      conn
      |> Plug.Test.init_test_session(%{user_id: user.id})
      |> get(~p"/auth/logout?#{[device: @token]}")

    assert redirected_to(conn) == "/"
    refute Apns.registered?(user, @token)
    assert Apns.registered?(user, @other_token)

    # someone else's token in the URL forgets nothing of theirs
    stranger = user_fixture()

    build_conn()
    |> Plug.Test.init_test_session(%{user_id: stranger.id})
    |> get(~p"/auth/logout?#{[device: @other_token]}")

    assert Apns.registered?(user, @other_token)
  end
end
