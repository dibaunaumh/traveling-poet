defmodule TravelingPoet.Messaging.Notifier do
  @moduledoc """
  Sends a note to every channel the owner has paired when their poet publishes
  a journal entry, and when their credits run low. Opt-out of publish notes via
  poet settings `"notify"` (legacy key: `"telegram_notify"`).

  The wording here has to match the WhatsApp templates registered in the Meta
  dashboard — see `TravelingPoet.WhatsApp.Client`.
  """

  use GenServer
  require Logger

  alias TravelingPoet.{Accounts, Credits, Journal, Messaging, Poets}
  alias TravelingPoet.Messaging.Notification

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Whether the owner wants publish notes (legacy setting key still honoured)."
  def notify_enabled?(poet) do
    settings = poet.settings || %{}
    Map.get(settings, "notify", Map.get(settings, "telegram_notify", true))
  end

  @impl true
  def init(_opts) do
    if Messaging.configured_providers() == [] do
      :ignore
    else
      Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "journal:published")
      Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "credits:low")
      {:ok, %{}}
    end
  end

  @impl true
  def handle_info({:journal_published, poet_id, entry_id}, state) do
    with poet when not is_nil(poet) <- Poets.get_poet(poet_id),
         true <- notify_enabled?(poet),
         user when not is_nil(user) <- Accounts.get_user(poet.user_id) do
      entry = Journal.get_entry!(entry_id)
      base = Application.get_env(:traveling_poet, :phoenix_url, "")

      link =
        if poet.is_public,
          do: "#{base}/p/#{poet.slug}",
          else: "#{base}/journal/#{entry.entry_date}"

      place = entry.place_name || "the road"

      Messaging.notify(user, %Notification{
        key: :journal_published,
        params: [poet.name, place, link],
        text: "🖋 #{poet.name} published today's entry from #{place}. Read it here: #{link}",
        preview_url: true
      })
    else
      _ -> :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:credits_low, user_id, balance}, state) do
    with user when not is_nil(user) <- Accounts.get_user(user_id) do
      base = Application.get_env(:traveling_poet, :phoenix_url, "")
      poet = Poets.get_poet_by_user(user.id)
      name = (poet && poet.name) || "Your poet"
      settings_url = "#{base}/settings"

      notification =
        if balance <= 0 do
          %Notification{
            key: :credits_empty,
            params: [name, settings_url],
            text: "💤 #{name} has run out of credits and is resting. Top up: #{settings_url}"
          }
        else
          formatted = Credits.format(balance)

          %Notification{
            key: :credits_low,
            params: [name, formatted, settings_url],
            text:
              "⏳ #{name} has about #{formatted} credits left — a few days of travel. Top up: #{settings_url}"
          }
        end

      Messaging.notify(user, notification)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end
