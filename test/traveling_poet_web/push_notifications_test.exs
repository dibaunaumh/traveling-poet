defmodule TravelingPoetWeb.PushNotificationsTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Journal, WebPush}
  alias TravelingPoet.WebPush.Crypto

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  defp publish_entry(poet) do
    {:ok, entry} =
      Journal.upsert_entry(poet.id, ~D[2026-09-04], %{title: "Setting Out", place_name: "Lisbon"})

    {:ok, _} = Journal.replace_sections(entry, [%{kind: "description", body: "a day"}])
    {:ok, _} = Journal.publish_entry(entry)
    entry
  end

  defp browser_subscription(endpoint) do
    {ua_public, _} = :crypto.generate_key(:ecdh, :prime256v1)

    %{
      "endpoint" => endpoint,
      "keys" => %{"p256dh" => Crypto.b64(ua_public), "auth" => Crypto.b64(<<7::128>>)}
    }
  end

  defp owner do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    poet = poet_fixture(user, %{name: "Solveig"})
    {user, poet}
  end

  describe "journal nudge" do
    test "waits for the browser to report, then invites; 'not now' hides it", %{conn: conn} do
      {user, poet} = owner()
      publish_entry(poet)

      {:ok, view, html} = live(sign_in(conn, user), ~p"/journal")
      assert html =~ ~s(id="push-nudge")
      assert html =~ "data-vapid-key=\"#{WebPush.public_key()}\""
      refute html =~ "Turn on notifications"

      html = render_hook(view, "push_state", %{"state" => "available", "dismissed" => false})
      assert html =~ "Want a nudge when Solveig writes the next entry?"
      assert html =~ ~s(data-push-action="subscribe")
      assert html =~ ~s(data-push-action="dismiss")

      html = render_hook(view, "push_state", %{"state" => "available", "dismissed" => true})
      refute html =~ "Turn on notifications"
    end

    test "on an iPhone browser tab it explains Home Screen instead", %{conn: conn} do
      {user, poet} = owner()
      publish_entry(poet)
      {:ok, view, _} = live(sign_in(conn, user), ~p"/journal")

      html = render_hook(view, "push_state", %{"state" => "needs_install", "dismissed" => false})
      assert html =~ "Add to Home Screen"
      refute html =~ ~s(data-push-action="subscribe")
    end

    test "stays silent when unsupported, denied, or already subscribed", %{conn: conn} do
      {user, poet} = owner()
      publish_entry(poet)
      {:ok, view, _} = live(sign_in(conn, user), ~p"/journal")

      for state <- ~w(unsupported denied subscribed) do
        html = render_hook(view, "push_state", %{"state" => state, "dismissed" => false})
        refute html =~ "Want a nudge", "nudge shown for #{state}"
      end
    end

    test "no entry yet means nothing to nudge about", %{conn: conn} do
      {user, _poet} = owner()
      {:ok, _view, html} = live(sign_in(conn, user), ~p"/journal")
      refute html =~ ~s(id="push-nudge")
    end
  end

  describe "waiting tip" do
    test "offers notifications before any entry, with the promise", %{conn: conn} do
      {user, _poet} = owner()
      {:ok, view, html} = live(sign_in(conn, user), ~p"/journal")
      assert html =~ ~s(id="push-tip")
      assert html =~ "Never marketing"
      refute html =~ "Turn on notifications"

      html = render_hook(view, "push_state", %{"state" => "available", "dismissed" => false})
      assert html =~ "Get a nudge on this device when Solveig publishes."
      assert html =~ "Turn on notifications"
      assert html =~ ~s(data-push-action="subscribe")
    end

    test "on an iPhone browser tab it explains Home Screen", %{conn: conn} do
      {user, _poet} = owner()
      {:ok, view, _} = live(sign_in(conn, user), ~p"/journal")

      html = render_hook(view, "push_state", %{"state" => "needs_install", "dismissed" => false})
      assert html =~ "Add to Home Screen"
      refute html =~ ~s(data-push-action="subscribe")
    end

    test "a subscribed device is told what it will get", %{conn: conn} do
      {user, _poet} = owner()
      {:ok, view, _} = live(sign_in(conn, user), ~p"/journal")

      html = render_hook(view, "push_state", %{"state" => "subscribed", "dismissed" => false})
      assert html =~ "will get a nudge when the first entry is out"
    end

    test "the tip makes way for the nudge once an entry exists", %{conn: conn} do
      {user, poet} = owner()
      publish_entry(poet)
      {:ok, _view, html} = live(sign_in(conn, user), ~p"/journal")
      refute html =~ ~s(id="push-tip")
      assert html =~ ~s(id="push-nudge")
    end

    test "a successful subscribe is stored and acknowledged", %{conn: conn} do
      {user, poet} = owner()
      publish_entry(poet)
      {:ok, view, _} = live(sign_in(conn, user), ~p"/journal")

      html =
        render_hook(view, "push_subscribed", %{
          "subscription" => browser_subscription("https://push.example/phone")
        })

      assert html =~ "You&#39;ll get a nudge on this device when Solveig publishes."
      assert WebPush.count(user) == 1
      refute html =~ "Want a nudge"
    end

    test "a browser that already holds a subscription re-syncs it silently", %{conn: conn} do
      {user, poet} = owner()
      publish_entry(poet)
      {:ok, view, _} = live(sign_in(conn, user), ~p"/journal")

      render_hook(view, "push_state", %{
        "state" => "subscribed",
        "dismissed" => false,
        "subscription" => browser_subscription("https://push.example/rotated")
      })

      assert WebPush.subscribed?(user, "https://push.example/rotated")
    end
  end

  describe "settings switch" do
    test "turns on, counts devices, turns off", %{conn: conn} do
      {user, _poet} = owner()
      {:ok, view, html} = live(sign_in(conn, user), ~p"/settings")
      assert html =~ "Notifications"
      assert html =~ "Checking this device"

      html = render_hook(view, "push_state", %{"state" => "available", "dismissed" => false})
      assert html =~ "Nudge this device when Solveig publishes"
      assert html =~ ~s(data-push-action="subscribe")

      html =
        render_hook(view, "push_subscribed", %{
          "subscription" => browser_subscription("https://push.example/laptop")
        })

      assert html =~ "This device gets a nudge"
      assert html =~ ~s(data-push-action="unsubscribe")
      assert html =~ "1 device is subscribed"

      html =
        render_hook(view, "push_unsubscribed", %{"endpoint" => "https://push.example/laptop"})

      assert html =~ ~s(data-push-action="subscribe")
      refute html =~ "device is subscribed"
      assert WebPush.count(user) == 0
    end

    test "explains blocked and unsupported browsers", %{conn: conn} do
      {user, _poet} = owner()
      {:ok, view, _} = live(sign_in(conn, user), ~p"/settings")

      assert render_hook(view, "push_state", %{"state" => "denied"}) =~
               "Notifications are blocked"

      assert render_hook(view, "push_state", %{"state" => "unsupported"}) =~
               "can&#39;t receive push"

      assert render_hook(view, "push_state", %{"state" => "needs_install"}) =~ "Home Screen"
    end
  end

  test "the service worker is served from the site root as JavaScript", %{conn: conn} do
    conn = get(conn, "/sw.js")
    assert conn.status == 200
    assert [type] = get_resp_header(conn, "content-type")
    assert type =~ "javascript"
    assert conn.resp_body =~ ~s(addEventListener("push")
    assert conn.resp_body =~ "notificationclick"
  end
end
