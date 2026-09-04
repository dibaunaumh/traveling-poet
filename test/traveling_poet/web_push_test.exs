defmodule TravelingPoet.WebPushTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Journal, WebPush}
  alias TravelingPoet.WebPush.Crypto

  @stub TravelingPoet.WebPush

  defp browser_subscription(endpoint) do
    {ua_public, _} = :crypto.generate_key(:ecdh, :prime256v1)

    %{
      "endpoint" => endpoint,
      "keys" => %{
        "p256dh" => Crypto.b64(ua_public),
        "auth" => Crypto.b64(:crypto.strong_rand_bytes(16))
      }
    }
  end

  setup do
    user = user_fixture()
    poet = poet_fixture(user)
    %{user: user, poet: poet}
  end

  test "test config is wired for push" do
    assert WebPush.configured?()
  end

  test "subscribe is keyed by endpoint: re-reporting refreshes, never duplicates", %{user: user} do
    sub = browser_subscription("https://push.example/one")
    {:ok, a} = WebPush.subscribe(user, sub, user_agent: "Safari")
    {:ok, b} = WebPush.subscribe(user, put_in(sub, ["keys", "auth"], Crypto.b64(<<1::128>>)))

    assert a.id == b.id
    assert WebPush.count(user) == 1
    assert WebPush.subscribed?(user, "https://push.example/one")
    assert [%{auth: auth, user_agent: "Safari"}] = WebPush.list_subscriptions(user)
    assert auth == Crypto.b64(<<1::128>>)
  end

  test "a malformed or non-https subscription is refused", %{user: user} do
    assert {:error, :malformed_subscription} = WebPush.subscribe(user, %{"endpoint" => "x"})

    assert {:error, %Ecto.Changeset{}} =
             WebPush.subscribe(user, browser_subscription("http://push.example/insecure"))
  end

  test "unsubscribe only touches the caller's own row", %{user: user} do
    other = user_fixture()
    {:ok, _} = WebPush.subscribe(other, browser_subscription("https://push.example/theirs"))
    {:ok, _} = WebPush.subscribe(user, browser_subscription("https://push.example/mine"))

    :ok = WebPush.unsubscribe(user, "https://push.example/theirs")
    assert WebPush.count(other) == 1
    :ok = WebPush.unsubscribe(user, "https://push.example/mine")
    assert WebPush.count(user) == 0
  end

  test "publishing an entry pushes an encrypted, VAPID-signed nudge to every device", %{
    user: user,
    poet: poet
  } do
    {:ok, _} = WebPush.subscribe(user, browser_subscription("https://push.example/phone"))
    {:ok, _} = WebPush.subscribe(user, browser_subscription("https://push.example/laptop"))
    test_pid = self()

    Req.Test.stub(@stub, fn conn ->
      send(test_pid, {:pushed, conn, Req.Test.raw_body(conn)})
      Plug.Conn.send_resp(conn, 201, "")
    end)

    {:ok, entry} =
      Journal.upsert_entry(poet.id, ~D[2026-09-04], %{title: "Setting Out", place_name: "Lisbon"})

    {:ok, _} = Journal.publish_entry(entry)

    assert {2, 0} = WebPush.notify_entry(poet.id, entry.id)

    for _ <- 1..2 do
      assert_receive {:pushed, conn, body}
      assert conn.method == "POST"
      assert conn.host == "push.example"
      # (Req's test adapter strips content-* headers, so the coding header is
      # covered by the body shape below; Finch sends headers verbatim.)
      assert Plug.Conn.get_req_header(conn, "ttl") == ["86400"]
      assert [auth] = Plug.Conn.get_req_header(conn, "authorization")
      assert auth =~ ~r/^vapid t=[\w-]+\.[\w-]+\.[\w-]+,k=#{WebPush.public_key()}$/
      # Opaque to the push service: salt + record size + key id + ciphertext
      assert <<_salt::binary-16, 4096::unsigned-big-32, 65, _::binary>> = body
      refute body =~ "Setting Out"
    end

    assert Enum.all?(WebPush.list_subscriptions(user), & &1.last_sent_at)
  end

  test "a push service saying 410 Gone prunes that device; others keep working", %{
    user: user,
    poet: poet
  } do
    {:ok, dead} = WebPush.subscribe(user, browser_subscription("https://push.example/dead"))
    {:ok, live} = WebPush.subscribe(user, browser_subscription("https://push.example/live"))

    Req.Test.stub(@stub, fn conn ->
      status = if conn.request_path =~ "dead", do: 410, else: 201
      Plug.Conn.send_resp(conn, status, "")
    end)

    {:ok, entry} = Journal.upsert_entry(poet.id, ~D[2026-09-04], %{title: "T"})
    assert {1, 1} = WebPush.notify_entry(poet.id, entry.id)

    assert [%{id: id}] = WebPush.list_subscriptions(user)
    assert id == live.id
    refute Repo.get(WebPush.Subscription, dead.id)
  end

  test "a transient failure is recorded, not pruned", %{user: user, poet: poet} do
    {:ok, sub} = WebPush.subscribe(user, browser_subscription("https://push.example/flaky"))
    Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 500, "oops") end)

    {:ok, entry} = Journal.upsert_entry(poet.id, ~D[2026-09-04], %{title: "T"})
    assert {0, 0} = WebPush.notify_entry(poet.id, entry.id)
    assert %{last_error: "HTTP 500" <> _} = Repo.get(WebPush.Subscription, sub.id)
  end

  test "nobody subscribed is a quiet no-op", %{poet: poet} do
    {:ok, entry} = Journal.upsert_entry(poet.id, ~D[2026-09-04], %{title: "T"})
    assert {0, 0} = WebPush.notify_entry(poet.id, entry.id)
  end
end
