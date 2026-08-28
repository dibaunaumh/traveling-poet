defmodule TravelingPoetWeb.StripeWebhookController do
  @moduledoc """
  POST /webhooks/stripe. Verifies the signature over the raw body, then
  fulfils `checkout.session.completed` by crediting the pack named in the
  session metadata. Idempotent on the session id, so Stripe retries are safe.
  """

  use TravelingPoetWeb, :controller
  require Logger

  alias TravelingPoet.{Accounts, Credits}
  alias TravelingPoet.Payments.Stripe

  def handle(conn, params) do
    secret = Stripe.webhook_secret()
    header = conn |> get_req_header("stripe-signature") |> List.first()

    cond do
      is_nil(secret) ->
        conn |> put_status(503) |> json(%{error: "stripe webhook not configured"})

      (res = Stripe.verify_signature(conn.assigns[:raw_body], header, secret)) != :ok ->
        Logger.warning("stripe webhook rejected: #{inspect(res)}")
        conn |> put_status(400) |> json(%{error: "invalid signature"})

      true ->
        fulfil(params)
        json(conn, %{received: true})
    end
  end

  defp fulfil(%{"type" => "checkout.session.completed", "data" => %{"object" => session}}) do
    with %{"payment_status" => "paid", "id" => session_id, "metadata" => meta} <- session,
         {user_id, ""} <- Integer.parse(to_string(meta["user_id"])),
         user when not is_nil(user) <- Accounts.get_user(user_id) do
      case Credits.purchase(user, meta["pack_id"], "stripe:" <> session_id) do
        {:ok, :duplicate} ->
          Logger.info("stripe: replayed session #{session_id}")

        {:ok, _tx} ->
          Logger.info("stripe: credited #{meta["pack_id"]} to user #{user.id}")

        {:error, reason} ->
          Logger.error("stripe: could not fulfil #{session_id}: #{inspect(reason)}")
      end
    else
      other -> Logger.warning("stripe: unfulfillable session: #{inspect(other)}")
    end
  end

  defp fulfil(%{"type" => type}), do: Logger.debug("stripe: ignoring #{type}")
  defp fulfil(_), do: :ok
end
