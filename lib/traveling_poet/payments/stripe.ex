defmodule TravelingPoet.Payments.Stripe do
  @moduledoc """
  Stripe Checkout (hosted page) via `Req` — no SDK. Fulfilment happens in
  `StripeWebhookController` on `checkout.session.completed`, keyed by the
  session id so retries never double-credit.
  """

  @behaviour TravelingPoet.Payments

  @api "https://api.stripe.com/v1"
  @tolerance_s 300

  @impl true
  def start_checkout(user, pack, %{success: success, cancel: cancel}) do
    form = [
      {"mode", "payment"},
      {"success_url", success},
      {"cancel_url", cancel},
      {"client_reference_id", Integer.to_string(user.id)},
      {"customer_email", user.email},
      {"metadata[user_id]", Integer.to_string(user.id)},
      {"metadata[pack_id]", pack.id},
      {"line_items[0][quantity]", "1"},
      {"line_items[0][price_data][currency]", "usd"},
      {"line_items[0][price_data][unit_amount]", Integer.to_string(pack.cents)},
      {"line_items[0][price_data][product_data][name]", "#{pack.credits} Traveling Poet credits"}
    ]

    case Req.post("#{@api}/checkout/sessions", auth: {:bearer, secret_key()}, form: form) do
      {:ok, %{status: 200, body: %{"url" => url}}} -> {:ok, url}
      {:ok, %{status: status, body: body}} -> {:error, {:stripe, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  def secret_key, do: Application.get_env(:traveling_poet, :stripe_secret_key)
  def webhook_secret, do: Application.get_env(:traveling_poet, :stripe_webhook_secret)

  @doc """
  Verifies a `Stripe-Signature` header against the raw body:
  HMAC-SHA256 of `"<t>.<body>"`, constant-time compare, 5-minute tolerance.
  """
  def verify_signature(raw_body, header, secret, now \\ System.os_time(:second))

  def verify_signature(raw_body, header, secret, now)
      when is_binary(raw_body) and is_binary(header) and is_binary(secret) do
    parts =
      header
      |> String.split(",")
      |> Enum.map(&String.split(&1, "=", parts: 2))
      |> Enum.filter(&match?([_, _], &1))
      |> Enum.group_by(&hd/1, &List.last/1)

    with [t] <- Map.get(parts, "t", []),
         {ts, ""} <- Integer.parse(t),
         true <- abs(now - ts) <= @tolerance_s || {:error, :timestamp_out_of_tolerance},
         expected = sign(secret, "#{t}.#{raw_body}"),
         true <-
           Enum.any?(Map.get(parts, "v1", []), &Plug.Crypto.secure_compare(&1, expected)) ||
             {:error, :bad_signature} do
      :ok
    else
      {:error, _} = err -> err
      _ -> {:error, :malformed_signature}
    end
  end

  def verify_signature(_, _, _, _), do: {:error, :missing_signature}

  def sign(secret, payload) do
    :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower)
  end
end
