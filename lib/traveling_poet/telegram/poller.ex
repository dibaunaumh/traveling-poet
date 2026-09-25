defmodule TravelingPoet.Telegram.Poller do
  @moduledoc """
  Long-polling loop against the Telegram Bot API. Handles two kinds of
  inbound messages:

    * `/start <token>` — completes pairing (Telegram.Pairing)
    * anything else from a paired chat — relayed to the user's poet via
      AgentSession; the reply is sent back to the same chat

  Enabled only when TELEGRAM_BOT_TOKEN is set. Single-instance by design
  (two pollers would compete for updates) — the app runs on one machine.
  """

  use GenServer
  require Logger

  alias TravelingPoet.{Accounts, AgentSession, Poets, Usage}
  alias TravelingPoet.Telegram.{Client, Pairing}

  @poll_timeout_s 25
  @error_backoff_ms 10_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    if Client.configured?() do
      Logger.info("Telegram.Poller: polling as @#{Client.bot_username()}")
      send(self(), :poll)
      {:ok, %{offset: 0}}
    else
      Logger.info("Telegram.Poller: disabled (no TELEGRAM_BOT_TOKEN)")
      :ignore
    end
  end

  @impl true
  def handle_info(:poll, state) do
    state =
      case Client.get_updates(state.offset, @poll_timeout_s) do
        {:ok, updates} ->
          Enum.each(updates, &handle_update/1)

          next_offset =
            updates |> Enum.map(& &1["update_id"]) |> Enum.max(fn -> state.offset - 1 end)

          send(self(), :poll)
          %{state | offset: next_offset + 1}

        {:error, reason} ->
          Logger.warning("Telegram.Poller: getUpdates failed: #{inspect(reason)}")
          Process.send_after(self(), :poll, @error_backoff_ms)
          state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp handle_update(%{"message" => %{"chat" => %{"id" => chat_id}, "text" => text} = message}) do
    username = get_in(message, ["from", "username"])

    case text do
      "/start " <> token ->
        handle_pairing(chat_id, String.trim(token), username)

      "/start" ->
        Client.send_message(
          chat_id,
          "Hello! To pair this chat with your traveling poet, use the pairing link from the app's onboarding or settings page."
        )

      _ ->
        handle_chat(chat_id, text)
    end
  end

  defp handle_update(_other), do: :ok

  defp handle_pairing(chat_id, token, username) do
    case Pairing.complete_pairing(token, chat_id, username) do
      {:ok, user} ->
        poet = TravelingPoet.Poets.get_poet_by_user(user.id)
        poet_name = (poet && poet.name) || "Your traveling poet"

        Client.send_message(
          chat_id,
          "✒️ Paired! #{poet_name} can now write to you here, and anything you send lands in your chat with them."
        )

      {:error, :invalid_token} ->
        Client.send_message(
          chat_id,
          "That pairing link has expired or was already used — please generate a fresh one from the app."
        )
    end
  end

  defp handle_chat(chat_id, text) do
    case Accounts.get_user_by_telegram_chat_id(chat_id) do
      nil ->
        Client.send_message(
          chat_id,
          "This chat isn't paired yet — grab a pairing link from the app to meet your poet."
        )

      user ->
        cond do
          not user.sprite_provisioned ->
            Client.send_message(chat_id, "Your poet is still packing — check the app.")

          TravelingPoet.Credits.exhausted?(user, Poets.get_poet_by_user(user.id)) ->
            Client.send_message(chat_id, "Your poet is out of credits — top up in Settings.")

          not Usage.within_budget?(user, "chat_turn") ->
            Client.send_message(
              chat_id,
              "Your poet is resting until tomorrow (daily limit reached)."
            )

          true ->
            Usage.record(user.id, "chat_turn", %{metadata: %{"channel" => "telegram"}})

            # Relay in a task so one slow agent turn doesn't block polling.
            Task.start(fn ->
              framed = TravelingPoet.Asks.frame_reply(user.id, text)

              case AgentSession.run(user, framed, channel: "telegram", record_as: text) do
                {:ok, ""} ->
                  Client.send_message(
                    chat_id,
                    "…the poet seems lost in thought. Try again in a bit?"
                  )

                {:ok, reply} ->
                  Client.send_message(chat_id, strip_markdown(reply),
                    disable_web_page_preview: true
                  )

                # Stalled mid-turn: send whatever arrived, but say it's partial
                # rather than pass it off as a finished thought.
                {:timeout, ""} ->
                  Client.send_message(
                    chat_id,
                    "…the poet seems lost in thought. Try again in a bit?"
                  )

                {:timeout, partial} ->
                  Client.send_message(
                    chat_id,
                    strip_markdown(partial) <>
                      "\n\n(…the poet trailed off mid-thought. Ask again to pick up the thread.)",
                    disable_web_page_preview: true
                  )

                {:error, _} ->
                  Client.send_message(
                    chat_id,
                    "Couldn't reach your poet just now — try again in a minute."
                  )
              end
            end)
        end
    end
  end

  # Telegram's default parse mode is plain text; strip the most jarring
  # markdown artifacts rather than risking parse_mode errors.
  defp strip_markdown(text) do
    text
    |> String.replace(~r/^#+\s*/m, "")
    |> String.replace("**", "")
  end
end
