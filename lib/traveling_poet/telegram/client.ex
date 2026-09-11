defmodule TravelingPoet.Telegram.Client do
  @moduledoc """
  Thin Req client for the Telegram Bot API — the only calls we need are
  `getUpdates` (long polling), `sendMessage` and `sendPhoto`.
  """

  require Logger

  @max_message_length 4096

  def configured? do
    bot_token() not in [nil, ""]
  end

  def bot_username do
    Application.get_env(:traveling_poet, :telegram_bot_username)
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

  @doc """
  Sends a photo from bytes with an optional `:caption`. Bytes, not a URL: the
  app's media route is owner-only for private poets, so Telegram could not
  fetch it. The caller keeps captions within Telegram's 1024-char cap.
  """
  def send_photo(chat_id, {bytes, filename, content_type}, opts \\ []) do
    fields =
      [
        chat_id: to_string(chat_id),
        photo: {bytes, filename: filename, content_type: content_type}
      ]
      |> maybe_put(:caption, opts[:caption])

    case Req.post(url("sendPhoto"), form_multipart: fields, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: %{"ok" => true}}} ->
        :ok

      {:ok, %{status: status, body: resp}} ->
        Logger.warning("Telegram sendPhoto failed (#{status}): #{inspect(resp)}")
        {:error, {status, resp}}

      {:error, reason} ->
        Logger.warning("Telegram sendPhoto error: #{inspect(reason)}")
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

  defp maybe_put(fields, _key, nil), do: fields
  defp maybe_put(fields, key, value) when is_list(fields), do: fields ++ [{key, value}]
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp url(method), do: "https://api.telegram.org/bot#{bot_token()}/#{method}"

  defp bot_token, do: Application.get_env(:traveling_poet, :telegram_bot_token)
end
