defmodule TravelingPoet.Telegram.Client do
  @moduledoc """
  Thin Req client for the Telegram Bot API — the only two calls we need are
  `getUpdates` (long polling) and `sendMessage`.

  Telegram takes free-form text at any time, so `send_notification/2` is just
  `send_message/3` with the notification's rendered text.
  """

  @behaviour TravelingPoet.Messaging.Adapter

  require Logger

  alias TravelingPoet.Messaging.Notification

  @max_message_length 4096

  @impl true
  def configured? do
    bot_token() not in [nil, ""]
  end

  @impl true
  def label, do: "Telegram"

  def bot_username do
    Application.get_env(:traveling_poet, :telegram_bot_username)
  end

  @impl true
  def pair_link(token) do
    case bot_username() do
      username when is_binary(username) and username != "" ->
        {:ok, "https://t.me/#{username}?start=#{token}"}

      _ ->
        {:error, :no_bot_username}
    end
  end

  @doc "Long-polls for updates. Blocks up to `timeout` seconds server-side."
  def get_updates(offset, timeout \\ 25) do
    case Req.get(url("getUpdates"),
           params: [offset: offset, timeout: timeout],
           receive_timeout: (timeout + 10) * 1000
         ) do
      {:ok, %{status: 200, body: %{"ok" => true, "result" => updates}}} ->
        {:ok, updates}

      {:ok, %{status: status, body: body}} ->
        {:error, {status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Sends a message, chunking anything over Telegram's 4096-char limit."
  @impl true
  def send_message(chat_id, text, opts \\ []) do
    text
    |> chunk_text()
    |> Enum.reduce_while(:ok, fn chunk, _acc ->
      case do_send(chat_id, chunk, opts) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  @impl true
  def send_notification(chat_id, %Notification{text: text, preview_url: preview?}) do
    send_message(chat_id, text, disable_web_page_preview: not preview?)
  end

  defp do_send(chat_id, text, opts) do
    body =
      %{chat_id: chat_id, text: text}
      |> maybe_put(:parse_mode, opts[:parse_mode])
      |> maybe_put(:disable_web_page_preview, opts[:disable_web_page_preview])

    case Req.post(url("sendMessage"), json: body, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: %{"ok" => true}}} ->
        :ok

      {:ok, %{status: status, body: resp}} ->
        Logger.warning("Telegram sendMessage failed (#{status}): #{inspect(resp)}")
        {:error, {status, resp}}

      {:error, reason} ->
        Logger.warning("Telegram sendMessage error: #{inspect(reason)}")
        {:error, reason}
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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp url(method), do: "https://api.telegram.org/bot#{bot_token()}/#{method}"

  defp bot_token, do: Application.get_env(:traveling_poet, :telegram_bot_token)
end
