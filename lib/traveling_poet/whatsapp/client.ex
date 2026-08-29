defmodule TravelingPoet.WhatsApp.Client do
  @moduledoc """
  WhatsApp Cloud API (Meta Graph) adapter.

  Two things differ from Telegram and drive the shape of this module:

    * **We don't poll.** Meta POSTs inbound messages to
      `/webhooks/whatsapp` — see `TravelingPoetWeb.WhatsAppWebhookController`.
    * **The 24-hour window.** Free-form text is only allowed within 24h of the
      user's last message to us. Anything the app initiates therefore goes out
      as a pre-approved *template*, which is what `send_notification/2` does.

  ## Templates to register (Meta dashboard → WhatsApp → Message templates)

  Category UTILITY, language `en` (override with `WHATSAPP_TEMPLATE_LANG`).
  The bodies must keep this variable order — `Messaging.Notification` fills
  them positionally:

    * `journal_published` —
      "🖋 {{1}} published today's entry from {{2}}. Read it here: {{3}}"
    * `credits_low` —
      "⏳ {{1}} has about {{2}} credits left — a few days of travel. Top up: {{3}}"
    * `credits_empty` —
      "💤 {{1}} has run out of credits and is resting. Top up: {{2}}"

  ## Configuration

    * `WHATSAPP_PHONE_NUMBER_ID` — the sending number's id (not the number)
    * `WHATSAPP_ACCESS_TOKEN` — System User token with `whatsapp_business_messaging`
    * `WHATSAPP_BUSINESS_NUMBER` — digits only, e.g. `15550123456`; used for
      the `wa.me` pairing link
    * `WHATSAPP_VERIFY_TOKEN` — any secret string; echoed back during webhook setup
    * `WHATSAPP_APP_SECRET` — verifies the `X-Hub-Signature-256` on webhooks
  """

  @behaviour TravelingPoet.Messaging.Adapter

  require Logger

  alias TravelingPoet.Messaging.Notification

  @graph_version "v21.0"
  @max_message_length 4096

  @templates %{
    journal_published: "journal_published",
    credits_low: "credits_low",
    credits_empty: "credits_empty"
  }

  @impl true
  def configured? do
    access_token() not in [nil, ""] and phone_number_id() not in [nil, ""]
  end

  @impl true
  def label, do: "WhatsApp"

  @impl true
  def pair_link(token) do
    case business_number() do
      number when is_binary(number) and number != "" ->
        text = URI.encode_www_form("PAIR #{token}")
        {:ok, "https://wa.me/#{String.replace(number, ~r/\D/, "")}?text=#{text}"}

      _ ->
        {:error, :no_business_number}
    end
  end

  @impl true
  def send_message(wa_id, text, opts \\ []) do
    # Accept Telegram's spelling of the same idea, so callers can pass one
    # set of options to either adapter.
    preview? =
      Keyword.get(opts, :preview_url, not Keyword.get(opts, :disable_web_page_preview, false))

    text
    |> chunk_text()
    |> Enum.reduce_while(:ok, fn chunk, _acc ->
      body = %{
        messaging_product: "whatsapp",
        recipient_type: "individual",
        to: wa_id,
        type: "text",
        text: %{body: chunk, preview_url: preview?}
      }

      case post(body) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  @impl true
  def send_notification(wa_id, %Notification{key: key, params: params}) do
    case Map.fetch(@templates, key) do
      {:ok, template} ->
        post(%{
          messaging_product: "whatsapp",
          recipient_type: "individual",
          to: wa_id,
          type: "template",
          template: %{
            name: template,
            language: %{code: template_language()},
            components: [
              %{
                type: "body",
                parameters: Enum.map(params, &%{type: "text", text: to_string(&1)})
              }
            ]
          }
        })

      :error ->
        {:error, {:no_template_for, key}}
    end
  end

  defp post(body) do
    if configured?() do
      url = "https://graph.facebook.com/#{@graph_version}/#{phone_number_id()}/messages"

      case Req.post(url,
             json: body,
             headers: [{"authorization", "Bearer #{access_token()}"}],
             receive_timeout: 15_000
           ) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: status, body: resp}} ->
          Logger.warning("WhatsApp send failed (#{status}): #{inspect(resp)}")
          {:error, {status, resp}}

        {:error, reason} ->
          Logger.warning("WhatsApp send error: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:error, :not_configured}
    end
  end

  defp chunk_text(text) do
    text
    |> String.codepoints()
    |> Enum.chunk_every(@max_message_length)
    |> Enum.map(&Enum.join/1)
    |> case do
      [] -> [""]
      chunks -> chunks
    end
  end

  ## Config accessors

  def phone_number_id, do: Application.get_env(:traveling_poet, :whatsapp_phone_number_id)
  def access_token, do: Application.get_env(:traveling_poet, :whatsapp_access_token)
  def business_number, do: Application.get_env(:traveling_poet, :whatsapp_business_number)
  def verify_token, do: Application.get_env(:traveling_poet, :whatsapp_verify_token)
  def app_secret, do: Application.get_env(:traveling_poet, :whatsapp_app_secret)

  def template_language,
    do: Application.get_env(:traveling_poet, :whatsapp_template_language) || "en"
end
