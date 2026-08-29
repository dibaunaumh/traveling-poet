defmodule TravelingPoet.Telegram.Poller do
  @moduledoc """
  Long-polling loop against the Telegram Bot API. Each text message is handed
  to `Messaging.Inbound`, which is shared with the WhatsApp webhook — this
  module only owns the transport and the update cursor.

  Enabled only when TELEGRAM_BOT_TOKEN is set. Single-instance by design
  (two pollers would compete for updates) — the app runs on one machine.
  """

  use GenServer
  require Logger

  alias TravelingPoet.Messaging.Inbound
  alias TravelingPoet.Telegram.Client

  @provider "telegram"
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
    Inbound.handle_text(@provider, chat_id, get_in(message, ["from", "username"]), text)
  end

  defp handle_update(%{"message" => %{"chat" => %{"id" => chat_id}}}) do
    Inbound.handle_unsupported(@provider, chat_id)
  end

  defp handle_update(_other), do: :ok
end
