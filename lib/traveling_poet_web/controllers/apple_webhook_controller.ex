defmodule TravelingPoetWeb.AppleWebhookController do
  @moduledoc """
  App Store Server Notifications (V2). Apple posts `{"signedPayload": jws}`;
  the signature is the authentication, checked against Apple's root like any
  transaction. A refund or a revoked purchase takes the credits back; the
  rest is acknowledged so Apple stops retrying.
  """
  use TravelingPoetWeb, :controller

  require Logger

  alias TravelingPoet.Payments.AppleIAP

  def handle(conn, %{"signedPayload" => signed}) when is_binary(signed) do
    case AppleIAP.handle_notification(signed) do
      {:ok, _} ->
        send_resp(conn, 200, "")

      {:error, reason} ->
        Logger.warning("apple webhook rejected: #{inspect(reason)}")
        send_resp(conn, 400, "")
    end
  end

  def handle(conn, _params), do: send_resp(conn, 400, "")
end
