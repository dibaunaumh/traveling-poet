defmodule TravelingPoet.Telegram.Notifier do
  @moduledoc """
  Sends a Telegram note to the paired owner when their poet publishes a
  journal entry. Opt-out via poet settings `"telegram_notify" => false`.
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
  def handle_info(_msg, state), do: {:noreply, state}
end
