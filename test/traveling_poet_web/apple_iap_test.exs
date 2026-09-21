defmodule TravelingPoetWeb.AppleIapTest do
  @moduledoc """
  Credits bought in the iOS app. Apple's side is a certificate chain made on
  the spot (`TestChain`); the code under test is told to trust that root
  instead of Apple's, and nothing else about it changes.
  """
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Credits, Repo, TestChain}
  alias TravelingPoet.Credits.CreditTransaction
  alias TravelingPoet.Payments.AppleIAP

  @app_ua "Mozilla/5.0 (iPhone; CPU iPhone OS 26_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 TravelingPoetiOS/1.0.0"
  @bundle "travel.poet.app"

  setup do
    apple = TestChain.generate()
    Application.put_env(:traveling_poet, :apple_iap_root_der, apple.root_der)
    Application.put_env(:traveling_poet, :apple_bundle_id, @bundle)

    on_exit(fn ->
      Application.delete_env(:traveling_poet, :apple_iap_root_der)
      Application.delete_env(:traveling_poet, :apple_bundle_id)
      Application.delete_env(:traveling_poet, :apple_iap_allow_xcode)
    end)

    user = user_fixture(%{onboarding_completed: true, ai_consent_at: DateTime.utc_now(:second)})
    %{apple: apple, user: user}
  end

  defp transaction(apple, user, overrides \\ %{}) do
    TestChain.sign(
      apple,
      Map.merge(
        %{
          "transactionId" => "2000000#{System.unique_integer([:positive])}",
          "bundleId" => @bundle,
          "productId" => "#{@bundle}.credits.p50",
          "appAccountToken" => AppleIAP.app_account_token(user),
          "environment" => "Production",
          "storefront" => "USA",
          "price" => 19_990,
          "currency" => "USD",
          "type" => "Consumable"
        },
        overrides
      )
    )
  end

  # as the page sends it: JSON, the CSRF header, a browser's Accept
  defp post_transaction(user, jws) do
    build_conn()
    |> Plug.Test.init_test_session(%{user_id: user.id})
    |> put_req_header("user-agent", @app_ua)
    |> put_req_header("accept", "*/*")
    |> put_req_header("content-type", "application/json")
    |> post(~p"/iap/apple/transactions", Jason.encode!(%{jws: jws}))
  end

  defp balance(user), do: Repo.reload(user).credits_balance

  describe "a purchase" do
    test "is credited once, however often StoreKit redelivers it", %{apple: apple, user: user} do
      before = balance(user)
      jws = transaction(apple, user)

      assert %{"status" => "credited", "finish" => true, "balance" => shown} =
               user |> post_transaction(jws) |> json_response(200)

      assert balance(user) == before + 50_000
      assert shown == Credits.format(before + 50_000)

      assert %{"status" => "duplicate", "finish" => true} =
               user |> post_transaction(jws) |> json_response(200)

      assert balance(user) == before + 50_000

      row = Repo.get_by!(CreditTransaction, user_id: user.id, kind: "purchase")
      assert "apple:2000000" <> _ = row.reference

      assert %{
               "provider" => "apple",
               "environment" => "Production",
               "storefront" => "USA",
               "pack_id" => "p50",
               "currency" => "USD"
             } = row.metadata
    end

    test "made in the sandbox counts: that is where App Review and TestFlight buy", %{
      apple: apple,
      user: user
    } do
      jws = transaction(apple, user, %{"environment" => "Sandbox"})
      assert %{"status" => "credited"} = user |> post_transaction(jws) |> json_response(200)

      assert %{"environment" => "Sandbox"} =
               Repo.get_by!(CreditTransaction, user_id: user.id, kind: "purchase").metadata
    end

    test "bought under another account stays with StoreKit for that account", %{
      apple: apple,
      user: user
    } do
      other = user_fixture()
      before = balance(user)
      jws = transaction(apple, other)

      assert %{"status" => "wrong_account", "finish" => false} =
               user |> post_transaction(jws) |> json_response(409)

      assert balance(user) == before

      # and with no token at all, which is how a receipt from outside the app would look
      assert %{"finish" => false} =
               user
               |> post_transaction(transaction(apple, user, %{"appAccountToken" => nil}))
               |> json_response(409)
    end

    test "is refused, and never finished, when it is not ours to credit", %{
      apple: apple,
      user: user
    } do
      before = balance(user)

      refused = [
        transaction(apple, user, %{"bundleId" => "com.someone.else"}),
        transaction(apple, user, %{"productId" => "#{@bundle}.credits.p9000"}),
        transaction(apple, user, %{"productId" => "com.someone.else.credits.p50"}),
        transaction(apple, user, %{"revocationDate" => 1_790_000_000_000}),
        transaction(apple, user, %{"environment" => "Xcode"}),
        transaction(apple, user, %{"transactionId" => nil}),
        # signed by somebody who is not Apple
        transaction(TestChain.generate(), user),
        "not.a.transaction"
      ]

      for jws <- refused do
        assert %{"status" => "refused", "finish" => false} =
                 user |> post_transaction(jws) |> json_response(422)
      end

      assert balance(user) == before

      refute Repo.get_by(CreditTransaction, user_id: user.id, kind: "purchase")
    end

    test "from Xcode's local StoreKit testing counts only where that is switched on", %{
      user: user
    } do
      # Xcode signs with a certificate that leads nowhere
      jws = transaction(TestChain.generate(), user, %{"environment" => "Xcode"})
      assert user |> post_transaction(jws) |> json_response(422)

      Application.put_env(:traveling_poet, :apple_iap_allow_xcode, true)
      assert %{"status" => "credited"} = user |> post_transaction(jws) |> json_response(200)

      # the switch opens nothing else: a production receipt still needs Apple's chain
      forged = transaction(TestChain.generate(), user, %{"environment" => "Production"})
      assert user |> post_transaction(forged) |> json_response(422)
    end

    test "needs someone signed in, and a CSRF token like any other form", %{
      apple: apple,
      user: user
    } do
      jws = transaction(apple, user)

      signed_out =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post(~p"/iap/apple/transactions", Jason.encode!(%{jws: jws}))

      assert redirected_to(signed_out) == "/"

      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        build_conn()
        |> Plug.Test.init_test_session(%{user_id: user.id})
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/iap/apple/transactions", Jason.encode!(%{jws: jws}))
      end
    end
  end

  describe "the purchase token" do
    test "is a version 4 UUID, the same every time, different for everyone", %{user: user} do
      token = AppleIAP.app_account_token(user)
      assert token =~ ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
      assert token == AppleIAP.app_account_token(user.id)
      assert token != AppleIAP.app_account_token(user_fixture())
    end
  end

  describe "a refund" do
    defp notify(apple, type, signed_transaction) do
      payload =
        TestChain.sign(apple, %{
          "notificationType" => type,
          "data" => %{
            "environment" => "Production",
            "bundleId" => @bundle,
            "signedTransactionInfo" => signed_transaction
          }
        })

      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(~p"/webhooks/apple", Jason.encode!(%{signedPayload: payload}))
    end

    test "takes the credits back, once", %{apple: apple, user: user} do
      before = balance(user)
      jws = transaction(apple, user)
      post_transaction(user, jws)
      assert balance(user) == before + 50_000

      assert notify(apple, "REFUND", jws).status == 200
      assert balance(user) == before

      assert notify(apple, "REFUND", jws).status == 200
      assert balance(user) == before

      refund = Repo.get_by!(CreditTransaction, user_id: user.id, kind: "purchase_refund")
      assert refund.amount == -50_000
      assert %{"shortfall" => 0, "apple_notification" => "REFUND"} = refund.metadata
    end

    test "after the credits were spent takes what is left and writes down the rest", %{
      apple: apple
    } do
      spender = user_fixture(%{credits: 0})
      jws = transaction(apple, spender)
      post_transaction(spender, jws)
      {:ok, _} = Credits.apply(spender, -(balance(spender) - 12_000), "admin_adjust")
      assert balance(spender) == 12_000

      assert notify(apple, "REVOKE", jws).status == 200
      assert balance(spender) == 0

      refund = Repo.get_by!(CreditTransaction, user_id: spender.id, kind: "purchase_refund")
      assert refund.amount == -12_000
      assert refund.metadata["shortfall"] == 38_000
    end

    test "for a purchase we never saw, or an account since deleted, is acknowledged", %{
      apple: apple,
      user: user
    } do
      assert notify(apple, "REFUND", transaction(apple, user)).status == 200

      gone = user_fixture()
      jws = transaction(apple, gone)
      post_transaction(gone, jws)
      {:ok, _} = TravelingPoet.Accounts.Purge.purge(gone.id, gone.email)
      assert notify(apple, "REFUND", jws).status == 200
    end

    test "other notifications are acknowledged and change nothing", %{apple: apple, user: user} do
      before = balance(user)
      assert notify(apple, "CONSUMPTION_REQUEST", transaction(apple, user)).status == 200
      assert notify(apple, "TEST", nil).status == 200
      assert balance(user) == before
    end

    test "a notification Apple did not sign is turned away", %{apple: apple, user: user} do
      jws = transaction(apple, user)
      post_transaction(user, jws)
      granted = balance(user)

      assert notify(TestChain.generate(), "REFUND", jws).status == 400
      assert build_conn() |> post(~p"/webhooks/apple", %{}) |> Map.get(:status) == 400
      assert balance(user) == granted
    end
  end

  describe "Settings in the app" do
    test "offers the packs through StoreKit, with this account's purchase token", %{
      conn: conn,
      user: user
    } do
      poet_fixture(user)

      conn =
        conn
        |> Plug.Test.init_test_session(%{user_id: user.id})
        |> put_req_header("user-agent", @app_ua)

      {:ok, view, html} = live(conn, ~p"/settings")

      assert has_element?(view, ~s(#apple-credit-packs[phx-hook="AppleIAP"]))
      assert html =~ AppleIAP.app_account_token(user)
      assert html =~ "travel.poet.app.credits.p10"
      assert html =~ "travel.poet.app.credits.p300"
      # no price from us: the device shows the App Store's own, in its currency
      refute html =~ "$5.00"
      refute html =~ "/credits/checkout"
    end

    test "a browser still gets the card checkout and no StoreKit", %{conn: conn, user: user} do
      poet_fixture(user)

      {:ok, view, _html} =
        live(Plug.Test.init_test_session(conn, %{user_id: user.id}), ~p"/settings")

      refute has_element?(view, "#apple-credit-packs")
      assert has_element?(view, "#credit-packs")
    end

    test "a refunded purchase reads as one in the activity list", %{
      conn: conn,
      apple: apple,
      user: user
    } do
      poet_fixture(user)
      jws = transaction(apple, user)
      post_transaction(user, jws)

      {:ok, _} =
        Credits.reverse_purchase(
          "apple:" <> elem(TravelingPoet.JWS.peek(jws), 2)["transactionId"]
        )

      {:ok, _view, html} =
        live(Plug.Test.init_test_session(conn, %{user_id: user.id}), ~p"/settings")

      assert html =~ "Purchase refunded"
    end
  end
end
