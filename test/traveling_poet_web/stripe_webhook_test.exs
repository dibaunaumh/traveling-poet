defmodule TravelingPoetWeb.StripeWebhookTest do
  use TravelingPoetWeb.ConnCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, Credits}
  alias TravelingPoet.Payments.Stripe

  @secret "whsec_test"

  setup do
    Application.put_env(:traveling_poet, :stripe_webhook_secret, @secret)
    on_exit(fn -> Application.delete_env(:traveling_poet, :stripe_webhook_secret) end)
    :ok
  end

  defp event(user, session_id, pack_id) do
    Jason.encode!(%{
      "id" => "evt_1",
      "type" => "checkout.session.completed",
      "data" => %{
        "object" => %{
          "id" => session_id,
          "payment_status" => "paid",
          "metadata" => %{"user_id" => to_string(user.id), "pack_id" => pack_id}
        }
      }
    })
  end

  defp post_signed(body, secret \\ @secret, t \\ System.os_time(:second)) do
    sig = "t=#{t},v1=#{Stripe.sign(secret, "#{t}.#{body}")}"

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("stripe-signature", sig)
    |> post(~p"/webhooks/stripe", body)
  end

  test "a signed checkout.session.completed credits the pack once" do
    user = user_fixture()
    body = event(user, "cs_test_1", "p100")

    assert json_response(post_signed(body), 200) == %{"received" => true}
    assert Credits.balance(Accounts.get_user!(user.id)) == 100_000

    # Stripe retries deliver the same session again
    assert json_response(post_signed(body), 200)
    assert Credits.balance(Accounts.get_user!(user.id)) == 100_000
  end

  test "a bad signature is rejected" do
    user = user_fixture()
    conn = post_signed(event(user, "cs_test_2", "p10"), "wrong-secret")
    assert json_response(conn, 400)
    assert Credits.balance(Accounts.get_user!(user.id)) == 0
  end

  test "a stale timestamp is rejected" do
    user = user_fixture()
    conn = post_signed(event(user, "cs_test_3", "p10"), @secret, System.os_time(:second) - 1000)
    assert json_response(conn, 400)
  end

  test "503 when no webhook secret is configured" do
    Application.delete_env(:traveling_poet, :stripe_webhook_secret)
    user = user_fixture()
    assert json_response(post_signed(event(user, "cs_test_4", "p10")), 503)
  end

  test "other event types are acknowledged and ignored" do
    body = Jason.encode!(%{"type" => "payment_intent.created", "data" => %{"object" => %{}}})
    assert json_response(post_signed(body), 200)
  end
end
