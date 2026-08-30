defmodule TravelingPoet.Messaging.Inbound do
  @moduledoc """
  Provider-independent handling of a message from a user: either it completes
  pairing, or it's chat for their poet. Fed by the Telegram poller and the
  WhatsApp webhook, which differ only in how the bytes arrive.
  """

  require Logger

  alias TravelingPoet.{Accounts, AgentSession, Credits, Messaging, Poets, Usage}
  alias TravelingPoet.Messaging.Channel

  # "/start <token>" (Telegram's deep-link convention) or "PAIR <token>"
  # (what wa.me prefills, since WhatsApp has no /start).
  @pair_command ~r/^(?:\/start|pair)\s+(\S+)$/i
  @start_command ~r/^\/start$/i

  @doc """
  Handles one inbound text. `external_id` is the provider's conversation id;
  `username` is a display handle if the provider gives us one.
  """
  def handle_text(provider, external_id, username, text) do
    external_id = to_string(external_id)
    trimmed = String.trim(text || "")

    cond do
      match = Regex.run(@pair_command, trimmed) ->
        handle_pairing(provider, external_id, username, Enum.at(match, 1))

      Regex.match?(@start_command, trimmed) ->
        Messaging.send_raw(
          provider,
          external_id,
          "Hello! To pair this chat with your traveling poet, use the pairing link from the app's onboarding or settings page."
        )

      true ->
        handle_chat(provider, external_id, trimmed)
    end
  end

  @doc "Reply for message types a poet can't read yet (photos, voice notes…)."
  def handle_unsupported(provider, external_id) do
    Messaging.send_raw(
      provider,
      to_string(external_id),
      "Your poet only reads words for now — send text and they'll write back."
    )
  end

  defp handle_pairing(provider, external_id, username, token) do
    case Messaging.complete_pairing(provider, token, external_id, username) do
      {:ok, user, _channel} ->
        poet = Poets.get_poet_by_user(user.id)
        poet_name = (poet && poet.name) || "Your traveling poet"

        Messaging.send_raw(
          provider,
          external_id,
          "✒️ Paired! #{poet_name} can now write to you here, and anything you send lands in your chat with them."
        )

      {:error, :invalid_token} ->
        Messaging.send_raw(
          provider,
          external_id,
          "That pairing link has expired or was already used — please generate a fresh one from the app."
        )
    end
  end

  defp handle_chat(provider, external_id, text) do
    case Messaging.get_channel_by_external_id(provider, external_id) do
      nil ->
        Messaging.send_raw(
          provider,
          external_id,
          "This chat isn't paired yet — grab a pairing link from the app to meet your poet."
        )

      %Channel{} = channel ->
        Messaging.touch_inbound(channel)
        relay(channel, provider, external_id, text)
    end
  end

  defp relay(channel, provider, external_id, text) do
    user = Accounts.get_user(channel.user_id)

    cond do
      is_nil(user) ->
        :ok

      not user.sprite_provisioned ->
        Messaging.send_raw(provider, external_id, "Your poet is still packing — check the app.")

      Credits.exhausted?(user, Poets.get_poet_by_user(user.id)) ->
        Messaging.send_raw(
          provider,
          external_id,
          "Your poet is out of credits — top up in Settings."
        )

      not Usage.within_budget?(user, "chat_turn") ->
        Messaging.send_raw(
          provider,
          external_id,
          "Your poet is resting until tomorrow (daily limit reached)."
        )

      true ->
        Usage.record(user.id, "chat_turn", %{metadata: %{"channel" => provider}})

        # Relay in a task so one slow agent turn doesn't block the poller or
        # hold a webhook request open.
        Task.start(fn -> run_turn(user, provider, external_id, text) end)
        :ok
    end
  end

  defp run_turn(user, provider, external_id, text) do
    case AgentSession.run(user, text, channel: provider) do
      {:ok, ""} ->
        Messaging.send_raw(
          provider,
          external_id,
          "…the poet seems lost in thought. Try again in a bit?"
        )

      {:ok, reply} ->
        Messaging.send_raw(provider, external_id, strip_markdown(reply),
          disable_web_page_preview: true
        )

      # Stalled mid-turn: send whatever arrived, but say it's partial rather
      # than pass it off as a finished thought. Silence here usually means the
      # model provider refused the call outright (an exhausted key 402s before
      # generating a token), so the reader gets nothing at all otherwise.
      {:timeout, ""} ->
        Messaging.send_raw(
          provider,
          external_id,
          "…the poet seems lost in thought. Try again in a bit?"
        )

      {:timeout, partial} ->
        Messaging.send_raw(
          provider,
          external_id,
          strip_markdown(partial) <>
            "\n\n(…the poet trailed off mid-thought. Ask again to pick up the thread.)",
          disable_web_page_preview: true
        )

      {:error, _} ->
        Messaging.send_raw(
          provider,
          external_id,
          "Couldn't reach your poet just now — try again in a minute."
        )
    end
  end

  # Neither provider renders our agent's markdown the way it's written;
  # strip the most jarring artifacts rather than risking parse errors.
  defp strip_markdown(text) do
    text
    |> String.replace(~r/^#+\s*/m, "")
    |> String.replace("**", "")
  end
end
