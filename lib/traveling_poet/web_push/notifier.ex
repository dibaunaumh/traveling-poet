defmodule TravelingPoet.WebPush.Notifier do
  @moduledoc """
  Listens for published entries and pushes a nudge to the owner's subscribed
  devices. Sibling of `Telegram.Notifier` on the same topic; no-op unless VAPID
  keys are configured.
  """

  use GenServer
  require Logger

  alias TravelingPoet.WebPush

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    if WebPush.configured?() and Application.get_env(:traveling_poet, :web_push_notifier, true) do
      Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "journal:published")
      {:ok, %{}}
    else
      :ignore
    end
  end

  @impl true
  def handle_info({:journal_published, poet_id, entry_id}, state) do
    # Off the GenServer so one slow push service can't delay the next poet.
    Task.start(fn ->
      {sent, pruned} = WebPush.notify_entry(poet_id, entry_id)

      if sent + pruned > 0 do
        Logger.info("web push: entry #{entry_id} — #{sent} sent, #{pruned} pruned")
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end
