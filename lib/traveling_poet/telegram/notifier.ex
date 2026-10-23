defmodule TravelingPoet.Telegram.Notifier do
  @moduledoc """
  Sends a Telegram note to the paired owner when their poet publishes a
  journal entry, when their credits run low, when a composed book edition
  is ready, when the poet asks them something (`Asks`), and when the poet
  answers a web chat message after they left (`ChatTurn`): the question or
  the answer itself, so a reply in Telegram reaches the poet as a chat turn.

  The admins hear of the business's own events on `"admin_events"`: a new
  sign-up and a credit purchase, through `Alerts.notify_admins/1`. Opt-out of publish notes via poet settings
  `"telegram_notify" => false`.

  A reader's note is written in their own language (`users.locale`, through
  `Locale.with_locale/2`): nothing else sets one for a background sender.
  The admins' pages stay English.
  """

  use GenServer
  use Gettext, backend: TravelingPoetWeb.Gettext
  require Logger

  alias TravelingPoet.{Accounts, Journal, Locale, Poets}
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
      Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "asks")
      Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "chat")
      Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "near_home")
      Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "admin_events")
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

      text =
        Locale.with_locale(user.locale, fn ->
          publish_text(poet, entry, Journal.journey_day(entry), entry_link(poet, entry))
        end)

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

      text =
        Locale.with_locale(user.locale, fn ->
          credits_low_text(poet, balance, "#{base}/settings")
        end)

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

      text =
        Locale.with_locale(user.locale, fn -> book_ready_text(poet, "#{base}/journal/book") end)

      Client.send_message(chat_id, text)
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
      link = "#{base}/journal/book/pdf/#{pdf_id}"
      text = Locale.with_locale(user.locale, fn -> book_pdf_text(poet, link) end)
      Client.send_message(chat_id, text)
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
      link = "#{base}/settings#trips"
      text = Locale.with_locale(user.locale, fn -> trip_suggested_text(poet, trip, link) end)
      Client.send_message(chat_id, text)
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
      link = "#{base}/settings#trips"
      text = Locale.with_locale(user.locale, fn -> trip_changed_text(poet, trip, link) end)
      Client.send_message(chat_id, text)
    else
      _ -> :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:reader_asked, user_id, ask_id}, state) do
    with user when not is_nil(user) <- Accounts.get_user(user_id),
         chat_id when is_integer(chat_id) <- user.telegram_chat_id,
         poet when not is_nil(poet) <- Poets.get_poet_by_user(user.id),
         %{} = ask <- TravelingPoet.Asks.get(ask_id) do
      text = Locale.with_locale(user.locale, fn -> question_text(poet, ask) end)
      Client.send_message(chat_id, text)
    else
      _ -> :ok
    end

    {:noreply, state}
  end

  # The week's picks near home (card-71): the names, and the way to the list
  @impl true
  def handle_info({:near_home_ready, user_id, _date}, state) do
    with user when not is_nil(user) <- Accounts.get_user(user_id),
         chat_id when is_integer(chat_id) <- user.telegram_chat_id,
         poet when not is_nil(poet) <- Poets.get_poet_by_user(user.id),
         [_ | _] = picks <- TravelingPoet.NearHome.this_week(user.id) do
      link = Application.get_env(:traveling_poet, :phoenix_url, "") <> "/guide/near"
      text = Locale.with_locale(user.locale, fn -> near_home_text(poet, picks, link) end)
      Client.send_message(chat_id, text)
    else
      _ -> :ok
    end

    {:noreply, state}
  end

  # The poet answered a web chat message after the reader left (ChatTurn):
  # the answer itself, so a reply in Telegram carries the conversation on
  @impl true
  def handle_info({:poet_replied, user_id, message_id}, state) do
    with user when not is_nil(user) <- Accounts.get_user(user_id),
         chat_id when is_integer(chat_id) <- user.telegram_chat_id,
         poet when not is_nil(poet) <- Poets.get_poet_by_user(user.id),
         %{user_id: ^user_id} = message <-
           TravelingPoet.Repo.get(TravelingPoet.Chat.ChatMessage, message_id) do
      text = Locale.with_locale(user.locale, fn -> reply_text(poet, message) end)
      Client.send_message(chat_id, text)
    else
      _ -> :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:user_signed_up, user_id, identity}, state) do
    with %{} = user <- Accounts.get_user(user_id) do
      TravelingPoet.Alerts.notify_admins(signup_alert_text(user, identity, user_count()))
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:credits_purchased, tx_id}, state) do
    with %{} = tx <- TravelingPoet.Repo.get(TravelingPoet.Credits.CreditTransaction, tx_id),
         %{} = user <- Accounts.get_user(tx.user_id) do
      TravelingPoet.Alerts.notify_admins(purchase_alert_text(user, tx))
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @doc "The poet's question as a Telegram message: its words, signed. Pure, for tests."
  def question_text(poet, ask),
    do:
      dgettext("notify", "%{question}\n\n(%{poet}. Just reply here.)",
        question: ask.question,
        poet: poet.name
      )

  # Telegram caps a message at 4096 characters
  @reply_max 3500

  @doc "The poet's chat answer as a Telegram message, signed. Pure, for tests."
  def reply_text(poet, message) do
    answer =
      if String.length(message.content) > @reply_max,
        do: String.slice(message.content, 0, @reply_max) <> "…",
        else: message.content

    dgettext("notify", "%{answer}\n\n(%{poet}. Just reply here.)",
      answer: answer,
      poet: poet.name
    )
  end

  @doc "The note that says the poet's credits are running out, or ran out. Pure, for tests."
  def credits_low_text(poet, balance, link) do
    name = (poet && poet.name) || dgettext("notify", "Your poet")

    if balance <= 0,
      do:
        dgettext("notify", "💤 %{poet} has run out of credits and is resting. Top up: %{link}",
          poet: name,
          link: link
        ),
      else:
        dgettext(
          "notify",
          "⏳ %{poet} has about %{credits} credits left — a few days of travel. Top up: %{link}",
          poet: name,
          credits: TravelingPoet.Credits.format(balance),
          link: link
        )
  end

  @doc "What the admins are told about a new sign-up. Pure, for tests."
  def signup_alert_text(user, identity, count) do
    via =
      case identity do
        :apple_id -> "Apple"
        :google_id -> "Google"
        _ -> "sign-in"
      end

    "New reader ##{count}: #{user.name || "(no name)"} <#{user.email}>, via #{via}.\n" <>
      TravelingPoet.Alerts.admin_url("/admin")
  end

  @doc "What the admins are told about a credit purchase. Pure, for tests."
  def purchase_alert_text(user, tx) do
    meta = tx.metadata || %{}
    [provider | _] = String.split(tx.reference || "unknown", ":", parts: 2)

    store =
      case {provider, meta["environment"]} do
        {"apple", "Sandbox"} -> "Apple, sandbox"
        {"apple", _} -> "Apple"
        {"stripe", _} -> "Stripe"
        {other, _} -> other
      end

    price =
      case meta["cents"] do
        cents when is_integer(cents) ->
          " for $" <> :erlang.float_to_binary(cents / 100, decimals: 2)

        _ ->
          ""
      end

    "Credits bought: #{user.name || "(no name)"} <#{user.email}>, " <>
      "#{TravelingPoet.Credits.format(tx.amount)} credits#{price} (#{store}).\n" <>
      TravelingPoet.Alerts.admin_url("/admin")
  end

  defp user_count, do: TravelingPoet.Repo.aggregate(TravelingPoet.Accounts.User, :count)

  @doc "The note with the week's picks near home, one per line. Pure, for tests."
  def near_home_text(poet, picks, link) do
    lines = Enum.map_join(picks, "\n", &"- #{&1.name}")

    dngettext(
      "notify",
      "%{poet} found something near you this week:\n%{lines}\n\nWhen and where: %{link}",
      "%{poet} found %{count} things near you this week:\n%{lines}\n\nWhen and where: %{link}",
      length(picks),
      poet: poet.name,
      lines: lines,
      link: link
    )
  end

  @doc "The note that says a planned trip moved on the calendar. Pure, for tests."
  def trip_changed_text(poet, trip, link) do
    dgettext(
      "notify",
      "Your trip to %{trip} is now %{dates}; %{poet} will set out on %{departure}. %{link}",
      trip: trip.name,
      dates: TravelingPoet.Trips.date_range(trip.start_date, trip.end_date),
      poet: poet.name,
      departure: TravelingPoet.Trips.date_range(trip.scout_from, trip.scout_from),
      link: link
    )
  end

  @doc "The note that says a trip was found on the calendar, to scout or not. Pure, for tests."
  def trip_suggested_text(poet, trip, link) do
    dgettext(
      "notify",
      "Your calendar has a trip to %{trip}, %{dates}. Should %{poet} scout it first? Decide here: %{link}",
      trip: trip.name,
      dates: TravelingPoet.Trips.date_range(trip.start_date, trip.end_date),
      poet: poet.name,
      link: link
    )
  end

  @doc "The note that says the book's PDF is ready. A link, not the file: it can be large. Pure, for tests."
  def book_pdf_text(poet, link),
    do:
      dgettext("notify", "📄 The PDF of your book with %{poet} is ready to download.\n%{link}",
        poet: poet.name,
        link: link
      )

  @doc "The note that says a composed edition is bound. Pure, for tests."
  def book_ready_text(poet, link),
    do:
      dgettext("notify", "📖 %{poet} has finished composing your book.\n%{link}",
        poet: poet.name,
        link: link
      )

  @doc """
  The note that goes out with a published entry, pure so it can be tested:
  the journey day, the poet, and the poet's own teaser (the title when it
  wrote none), then the link. The same words every day is what taught
  readers to ignore these.
  """
  def publish_text(poet, entry, day, link) do
    hook =
      blank_to_nil(entry.teaser) || blank_to_nil(entry.title) || fallback_hook(entry)

    dgettext("notify", "Day %{day} · %{poet}: %{hook}\n%{link}",
      day: day,
      poet: poet.name,
      hook: hook,
      link: link
    )
  end

  defp fallback_hook(entry) do
    case TravelingPoet.Topics.label_for_entry(entry) do
      nil ->
        case entry.place_name do
          nil -> dgettext("notify", "a new entry from the road")
          place -> dgettext("notify", "a new entry from %{place}", place: place)
        end

      label ->
        dgettext("notify", "an excursion into %{topic}", topic: label)
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
