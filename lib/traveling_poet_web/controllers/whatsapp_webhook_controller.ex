defmodule TravelingPoetWeb.WhatsAppWebhookController do
  @moduledoc """
  Meta's WhatsApp Cloud API webhook.

    * `GET /webhooks/whatsapp` — the subscription handshake: echo
      `hub.challenge` back when `hub.verify_token` matches ours.
    * `POST /webhooks/whatsapp` — inbound messages and delivery statuses,
      signed with `X-Hub-Signature-256` over the raw body.

  Meta redelivers until it gets a 200 and disables the webhook after enough
  failures, so we answer immediately and do the work off the request: dedupe
  on message id (`Messaging.Dedupe`) and hand text to `Messaging.Inbound`.
  """

  use TravelingPoetWeb, :controller
  require Logger

  alias TravelingPoet.Messaging.{Dedupe, Inbound}
  alias TravelingPoet.WhatsApp.Client

  @provider "whatsapp"

  def verify(conn, %{
        "hub.mode" => "subscribe",
        "hub.verify_token" => token,
        "hub.challenge" => challenge
      }) do
    expected = Client.verify_token()

    if is_binary(expected) and expected != "" and Plug.Crypto.secure_compare(token, expected) do
      conn |> put_resp_content_type("text/plain") |> send_resp(200, challenge)
    else
      Logger.warning("whatsapp webhook: verify token mismatch")
      send_resp(conn, 403, "")
    end
  end

  def verify(conn, _params), do: send_resp(conn, 400, "")

  def handle(conn, params) do
    signature = conn |> get_req_header("x-hub-signature-256") |> List.first()

    case verify_signature(conn.assigns[:raw_body], signature) do
      :ok ->
        Task.start(fn -> process(params) end)
        json(conn, %{received: true})

      {:error, reason} ->
        Logger.warning("whatsapp webhook rejected: #{inspect(reason)}")
        conn |> put_status(400) |> json(%{error: "invalid signature"})
    end
  end

  defp verify_signature(raw_body, "sha256=" <> digest) when is_binary(raw_body) do
    case Client.app_secret() do
      secret when is_binary(secret) and secret != "" ->
        expected =
          :hmac
          |> :crypto.mac(:sha256, secret, raw_body)
          |> Base.encode16(case: :lower)

        if Plug.Crypto.secure_compare(expected, String.downcase(digest)),
          do: :ok,
          else: {:error, :signature_mismatch}

      _ ->
        {:error, :no_app_secret}
    end
  end

  defp verify_signature(nil, _), do: {:error, :no_raw_body}
  defp verify_signature(_, _), do: {:error, :missing_signature}

  defp process(%{"entry" => entries}) when is_list(entries) do
    for entry <- entries,
        change <- entry["changes"] || [],
        change["field"] == "messages",
        value = change["value"] || %{},
        message <- value["messages"] || [] do
      handle_message(message, value["contacts"] || [])
    end

    :ok
  end

  defp process(_), do: :ok

  defp handle_message(%{"id" => id, "from" => from} = message, contacts) do
    if Dedupe.fresh?(id) do
      name = profile_name(contacts, from)

      case message do
        %{"type" => "text", "text" => %{"body" => body}} ->
          Inbound.handle_text(@provider, from, name, body)

        # A tapped quick-reply/CTA button carries its text payload.
        %{"type" => "button", "button" => %{"text" => text}} ->
          Inbound.handle_text(@provider, from, name, text)

        %{"type" => type} ->
          Logger.debug("whatsapp: unsupported message type #{type}")
          Inbound.handle_unsupported(@provider, from)
      end
    else
      Logger.debug("whatsapp: ignoring redelivered message #{id}")
    end
  end

  defp handle_message(_message, _contacts), do: :ok

  defp profile_name(contacts, wa_id) do
    Enum.find_value(contacts, fn contact ->
      if contact["wa_id"] == wa_id, do: get_in(contact, ["profile", "name"])
    end)
  end
end
