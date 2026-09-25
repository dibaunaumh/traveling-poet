defmodule TravelingPoet.WebPush.Notifier do
  @moduledoc """
  Listens for published entries and ready book editions, and pushes a nudge
  to the owner's subscribed devices. Sibling of `Telegram.Notifier` on the
  same topics; no-op unless VAPID keys are configured.
  """

  use GenServer
  require Logger

  alias TravelingPoet.WebPush

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    # Either road being open is reason enough to listen: browsers (VAPID
    # keys) or the iOS app (the Apple key); see WebPush.notify_user/2.
    if (WebPush.configured?() or TravelingPoet.Apns.configured?()) and
         Application.get_env(:traveling_poet, :web_push_notifier, true) do
      Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "journal:published")
      Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "books")
      Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "trips")
      Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "asks")
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
  def handle_info({:reader_asked, user_id, ask_id}, state) do
    Task.start(fn ->
      {sent, pruned} = WebPush.notify_poet_question(user_id, ask_id)

      if sent + pruned > 0 do
        Logger.info("web push: ask #{ask_id} — #{sent} sent, #{pruned} pruned")
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:book_ready, user_id, edition_id}, state) do
    Task.start(fn ->
      {sent, pruned} = WebPush.notify_book_ready(user_id, edition_id)

      if sent + pruned > 0 do
        Logger.info("web push: book edition #{edition_id} — #{sent} sent, #{pruned} pruned")
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:book_pdf_ready, user_id, pdf_id}, state) do
    Task.start(fn -> WebPush.notify_book_pdf_ready(user_id, pdf_id) end)
    {:noreply, state}
  end

  @impl true
  def handle_info({:trip_suggested, user_id, trip_id}, state) do
    Task.start(fn -> WebPush.notify_trip_suggested(user_id, trip_id) end)
    {:noreply, state}
  end

  @impl true
  def handle_info({:trip_changed, user_id, trip_id}, state) do
    Task.start(fn -> WebPush.notify_trip_changed(user_id, trip_id) end)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end
