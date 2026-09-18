defmodule TravelingPoet.Telegram.Notifier do
  @moduledoc """
  Sends a Telegram note to the paired owner when their poet publishes a
  journal entry, when their credits run low, and when a composed book
  edition is ready. Opt-out of publish notes via poet settings
  `"telegram_notify" => false`.
  """

  use GenServer
  require Logger

  alias TravelingPoet.{Accounts, Journal, Poets}
  alias TravelingPoet.Storage.S3
  alias TravelingPoet.Telegram.Client

  # Telegram caps a photo caption at 1024 characters.
  @caption_max 1024

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    if Client.configured?() do
      Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "journal:published")
      Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "credits:low")
      Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "books")
      Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "trips")
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
      text = publish_text(poet, entry, Journal.journey_day(entry), entry_link(poet, entry))
      send_publish_note(chat_id, text, Journal.entry_illustration(entry))
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
  def handle_info({:book_ready, user_id, _edition_id}, state) do
    with user when not is_nil(user) <- Accounts.get_user(user_id),
         chat_id when is_integer(chat_id) <- user.telegram_chat_id,
         poet when not is_nil(poet) <- Poets.get_poet_by_user(user.id) do
      base = Application.get_env(:traveling_poet, :phoenix_url, "")
      Client.send_message(chat_id, book_ready_text(poet, "#{base}/journal/book"))
    else
      _ -> :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:book_pdf_ready, user_id, pdf_id}, state) do
    with user when not is_nil(user) <- Accounts.get_user(user_id),
         chat_id when is_integer(chat_id) <- user.telegram_chat_id,
         poet when not is_nil(poet) <- Poets.get_poet_by_user(user.id) do
      base = Application.get_env(:traveling_poet, :phoenix_url, "")
      Client.send_message(chat_id, book_pdf_text(poet, "#{base}/journal/book/pdf/#{pdf_id}"))
    else
      _ -> :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:trip_suggested, user_id, trip_id}, state) do
    with user when not is_nil(user) <- Accounts.get_user(user_id),
         chat_id when is_integer(chat_id) <- user.telegram_chat_id,
         poet when not is_nil(poet) <- Poets.get_poet_by_user(user.id),
         trip when not is_nil(trip) <- TravelingPoet.Trips.get(poet.id, trip_id) do
      base = Application.get_env(:traveling_poet, :phoenix_url, "")
      Client.send_message(chat_id, trip_suggested_text(poet, trip, "#{base}/settings#trips"))
    else
      _ -> :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:trip_changed, user_id, trip_id}, state) do
    with user when not is_nil(user) <- Accounts.get_user(user_id),
         chat_id when is_integer(chat_id) <- user.telegram_chat_id,
         poet when not is_nil(poet) <- Poets.get_poet_by_user(user.id),
         trip when not is_nil(trip) <- TravelingPoet.Trips.get(poet.id, trip_id) do
      base = Application.get_env(:traveling_poet, :phoenix_url, "")
      Client.send_message(chat_id, trip_changed_text(poet, trip, "#{base}/settings#trips"))
    else
      _ -> :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @doc "The note that says a planned trip moved on the calendar. Pure, for tests."
  def trip_changed_text(poet, trip, link) do
    "Your trip to #{trip.name} is now " <>
      "#{TravelingPoet.Trips.date_range(trip.start_date, trip.end_date)}; " <>
      "#{poet.name} will set out on " <>
      "#{TravelingPoet.Trips.date_range(trip.scout_from, trip.scout_from)}. #{link}"
  end

  @doc "The note that says a trip was found on the calendar, to scout or not. Pure, for tests."
  def trip_suggested_text(poet, trip, link) do
    "Your calendar has a trip to #{trip.name}, " <>
      "#{TravelingPoet.Trips.date_range(trip.start_date, trip.end_date)}. " <>
      "Should #{poet.name} scout it first? Decide here: #{link}"
  end

  @doc "The note that says the book's PDF is ready. A link, not the file: it can be large. Pure, for tests."
  def book_pdf_text(poet, link),
    do: "📄 The PDF of your book with #{poet.name} is ready to download.\n#{link}"

  @doc "The note that says a composed edition is bound. Pure, for tests."
  def book_ready_text(poet, link),
    do: "📖 #{poet.name} has finished composing your book.\n#{link}"

  @doc """
  The note that goes out with a published entry, pure so it can be tested:
  the journey day, the poet, and the poet's own teaser (the title when it
  wrote none), then the link. The same words every day is what taught
  readers to ignore these.
  """
  def publish_text(poet, entry, day, link) do
    hook =
      blank_to_nil(entry.teaser) || blank_to_nil(entry.title) || fallback_hook(entry)

    "Day #{day} · #{poet.name}: #{hook}\n#{link}"
  end

  defp fallback_hook(entry) do
    case TravelingPoet.Topics.label_for_entry(entry) do
      nil -> "a new entry from #{entry.place_name || "the road"}"
      label -> "an excursion into #{label}"
    end
  end

  @doc "Always the announced entry's own page, never the journal index (which would show whatever is newest by the time it is opened)."
  def entry_link(poet, entry), do: TravelingPoet.Books.Urls.entry_url(poet, entry)

  # The drawing goes with the note when there is one. It is uploaded as bytes:
  # a private poet's /media/:id is owner-only, so Telegram could never fetch
  # it by URL. Any failure along the way falls back to the plain text note.
  defp send_publish_note(chat_id, text, nil), do: send_text(chat_id, text)

  defp send_publish_note(chat_id, text, media) do
    with {:ok, bytes} <- S3.download_file(media.s3_key),
         :ok <-
           Client.send_photo(chat_id, {bytes, filename(media), media.content_type},
             caption: String.slice(text, 0, @caption_max)
           ) do
      :ok
    else
      _ -> send_text(chat_id, text)
    end
  end

  defp send_text(chat_id, text),
    do: Client.send_message(chat_id, text, disable_web_page_preview: false)

  defp filename(media), do: "drawing-#{media.id}#{Path.extname(media.s3_key || ".png")}"

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
