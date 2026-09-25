defmodule TravelingPoet.AdminAlertsTest do
  @moduledoc """
  The admins hear of a new sign-up and of each credit purchase, once: a
  returning sign-in and a replayed webhook say nothing.
  """
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, Credits}
  alias TravelingPoet.Credits.CreditTransaction
  alias TravelingPoet.Telegram.Notifier

  setup do
    Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "admin_events")
    :ok
  end

  test "a new sign-up is announced; signing in again is not" do
    info = %{
      "sub" => "g-#{System.unique_integer([:positive])}",
      "email" => "wren@example.com",
      "email_verified" => true,
      "name" => "Wren"
    }

    {:ok, user} = Accounts.find_or_create_from_oauth(:google, info)
    assert_receive {:user_signed_up, id, :google_id}
    assert id == user.id

    {:ok, _} = Accounts.find_or_create_from_oauth(:google, info)
    refute_receive {:user_signed_up, _, _}
  end

  test "a purchase is announced once; a webhook replay is not" do
    user = user_fixture()

    {:ok, %CreditTransaction{id: tx_id}} = Credits.purchase(user, "p50", "stripe:cs_test_1")
    assert_receive {:credits_purchased, ^tx_id}

    assert {:ok, :duplicate} = Credits.purchase(user, "p50", "stripe:cs_test_1")
    refute_receive {:credits_purchased, _}
  end

  test "what the admins read" do
    user = %{name: "Wren", email: "wren@example.com"}

    signup = Notifier.signup_alert_text(user, :apple_id, 42)
    assert signup =~ "New reader #42: Wren <wren@example.com>, via Apple."
    assert signup =~ "/admin"

    tx = %CreditTransaction{
      amount: 50_000,
      reference: "apple:2000000123",
      metadata: %{"cents" => 2000, "environment" => "Sandbox"}
    }

    purchase = Notifier.purchase_alert_text(user, tx)

    assert purchase =~
             "Credits bought: Wren <wren@example.com>, 50 credits for $20.00 (Apple, sandbox)."

    stripe =
      Notifier.purchase_alert_text(user, %{
        tx
        | reference: "stripe:cs_1",
          metadata: %{"cents" => 500}
      })

    assert stripe =~ "for $5.00 (Stripe)"
  end
end
