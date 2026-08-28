defmodule TravelingPoet.Telegram.Notifier do
  @moduledoc """
  Sends a Telegram note to the paired owner when their poet publishes a
  journal entry, and when their credits run low. Opt-out of publish notes
  via poet settings `"telegram_notify" => false`.
  """

  use GenServer
  require Logger

  alias TravelingPoet.{Accounts, Journal, Poets}
  alias TravelingPoet.Telegram.Client

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    if Client.configured?() do
      Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "journal:published")
      Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "credits:low")
      {:ok, %{}}
    else
      :ignore
    end
  end

  @impl true
  def handle_info({:journal_published, poet_id, entry_id}, state) do
    with poet when not is_nil(poet) <- Poets.get_poet(poet_id),
         true <- Map.get(poet.settings || %{}, "telegram_notify", true),
         user when not is_nil(user) <- Accounts.get_user(poet.user_id),
         chat_id when is_integer(chat_id) <- user.telegram_chat_id do
      entry = Journal.get_entry!(entry_id)
      base = Application.get_env(:traveling_poet, :phoenix_url, "")

      link =
        if poet.is_public,
          do: "#{base}/p/#{poet.slug}",
          else: "#{base}/journal/#{entry.entry_date}"

      Client.send_message(
        chat_id,
        "🖋 #{poet.name} published today's entry from #{entry.place_name || "the road"}: #{link}",
        disable_web_page_preview: false
      )
    else
      _ -> :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:credits_low, user_id, balance}, state) do
    with user when not is_nil(user) <- Accounts.get_user(user_id),
         chat_id when is_integer(chat_id) <- user.telegram_chat_id do
      base = Application.get_env(:traveling_poet, :phoenix_url, "")
      poet = Poets.get_poet_by_user(user.id)
      name = (poet && poet.name) || "Your poet"

      text =
        if balance <= 0,
          do: "💤 #{name} has run out of credits and is resting. Top up: #{base}/settings",
          else:
            "⏳ #{name} has about #{TravelingPoet.Credits.format(balance)} credits left — a few days of travel. Top up: #{base}/settings"

      Client.send_message(chat_id, text)
    else
      _ -> :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end
