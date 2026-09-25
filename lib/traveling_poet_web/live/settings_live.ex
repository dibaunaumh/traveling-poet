defmodule TravelingPoetWeb.SettingsLive do
  use TravelingPoetWeb, :live_view

  import TravelingPoetWeb.PushNotifications, only: [assign_push: 1, push_settings: 1]
  import TravelingPoetWeb.TelegramPairing, only: [assign_telegram: 1, telegram_settings: 1]
  import TravelingPoetWeb.TripSuggestions, only: [assign_trips: 1, trip_settings: 1]

  import TravelingPoetWeb.PoetComponents

  alias TravelingPoet.{
    Accounts,
    Books,
    Credits,
    Geocoder,
    Payments,
    Poets,
    Preferences,
    Provisioner
  }

  alias TravelingPoet.Poets.{Poet, Presets}
  alias TravelingPoet.Topics
  alias TravelingPoet.Topics.Topic

  @impl true
  def mount(params, _session, socket) do
    user = socket.assigns.current_user
    poet = Poets.get_poet_by_user(user.id)

    socket =
      if params["purchased"] == "1",
        do: put_flash(socket, :info, "Credits added — happy travels!"),
        else: socket

    # Back from the iOS app's sign-in sheet after connecting Drive or
    # Calendar: the outcome arrives as a code, because a flash set over there
    # lives in Safari's session, not this one.
    socket =
      case TravelingPoetWeb.NativeAuth.connect_notice(params["connected"]) do
        {kind, text} -> put_flash(socket, kind, text)
        nil -> socket
      end

    if connected?(socket) do
      Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "user:#{user.id}")
    end

    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:user, user)
     |> assign(:poet, poet)
     |> assign_push()
     |> assign_telegram()
     |> assign(:packs, Credits.packs())
     |> assign(:reading_list, Geocoder.reading_list())
     |> assign(:payments_mock, Payments.mock?())
     |> assign_credits()
     |> assign(:stops, (poet && Poets.list_stops(poet.id)) || [])
     |> assign(:stop_query, "")
     |> assign(:stop_results, [])
     |> assign(:stop_error, nil)
     |> assign_topics()
     |> assign_learned()
     |> assign_book()
     |> assign_trips()}
  end

  # The composed edition: what it would cost, whether it can start, and how
  # the newest one went. Re-read whenever an edition or the balance changes.
  defp assign_book(socket) do
    case socket.assigns.poet do
      nil ->
        assign(socket, book: nil)

      poet ->
        user = socket.assigns.user
        manuscript = Books.manuscript(poet)

        assign(socket,
          book: %{
            edition: Books.current_edition(poet),
            cost: Books.compose_cost(manuscript),
            exempt: user.quota_exempt,
            chapters: length(manuscript.chapters),
            blocker:
              case Books.compose_blocker(user, poet, manuscript) do
                :ok -> nil
                {:blocked, reason} -> reason
              end,
            pdf_enabled: Books.pdf_enabled?(user),
            pdf: Books.current_pdf(poet),
            last_ready_pdf: Books.latest_ready_pdf(poet),
            drive_connected: TravelingPoet.GoogleDrive.connected?(user),
            has_composed: not is_nil(Books.latest_ready_edition(poet)),
            pdf_blocker:
              case Books.pdf_blocker(user, poet, manuscript) do
                :ok -> nil
                {:blocked, reason} -> reason
              end
          }
        )
    end
  end

  defp assign_topics(socket) do
    case socket.assigns.poet do
      nil ->
        socket |> assign(:topics, []) |> assign(:queued_excursions, [])

      poet ->
        socket
        |> assign(:topics, Topics.list(poet.id))
        |> assign(:queued_excursions, Topics.list_queued(poet.id))
    end
  end

  defp assign_learned(socket) do
    case socket.assigns.poet do
      nil ->
        socket |> assign(:learned, []) |> assign(:dismissed, [])

      poet ->
        socket
        |> assign(:learned, Preferences.list_active(poet.id))
        |> assign(:dismissed, Preferences.list_dismissed(poet.id))
    end
  end

  defp source_label("tap"), do: "you tapped this"
  defp source_label("chat"), do: "you said this in chat"
  defp source_label("settings"), do: "you set this"
  defp source_label("onboarding"), do: "from your setup"
  defp source_label("reaction"), do: "from your reaction"
  defp source_label("marker"), do: "from your markers"
  defp source_label(_), do: "learned"

  @impl true
  def handle_event("push_" <> _ = event, params, socket),
    do: TravelingPoetWeb.PushNotifications.handle_event(event, params, socket)

  @impl true
  def handle_event("telegram_" <> _ = event, params, socket),
    do: TravelingPoetWeb.TelegramPairing.handle_event(event, params, socket)

  @impl true
  def handle_event("trip_" <> _ = event, params, socket) do
    {:noreply, socket} = TravelingPoetWeb.TripSuggestions.handle_event(event, params, socket)
    # a planned trip's stops join the itinerary; a called-off one leaves it
    {:noreply, assign(socket, :stops, Poets.list_stops(socket.assigns.poet.id))}
  end

  @impl true
  def handle_event("dismiss_preference", %{"id" => id}, socket) do
    poet = socket.assigns.poet

    with {id, ""} <- Integer.parse(id),
         pref when not is_nil(pref) <- Preferences.get(poet.id, id),
         {:ok, _} <- Preferences.dismiss(pref) do
      {:noreply, assign_learned(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("restore_preference", %{"id" => id}, socket) do
    poet = socket.assigns.poet

    with {id, ""} <- Integer.parse(id),
         pref when not is_nil(pref) <- Preferences.get(poet.id, id),
         {:ok, _} <- Preferences.restore(pref) do
      {:noreply, assign_learned(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  ## Topics

  @impl true
  def handle_event("add_topic", %{"label" => label} = params, socket) do
    poet = socket.assigns.poet

    case String.trim(label || "") do
      "" ->
        {:noreply, socket}

      label ->
        attrs = %{label: label, kind: parse_kind(params["kind"])}

        case Topics.create(poet.id, attrs) do
          {:ok, _} ->
            {:noreply, assign_topics(socket)}

          {:error, changeset} ->
            {:noreply, put_flash(socket, :error, topic_error(changeset))}
        end
    end
  end

  @impl true
  def handle_event("save_topic", %{"topic_id" => id} = params, socket) do
    with_topic(socket, id, fn topic ->
      attrs = %{
        kind: parse_kind(params["kind"]),
        every_days: parse_cadence(params["every_days"], topic.every_days)
      }

      # A half-retyped label keeps the current one, as the poet's name does.
      attrs =
        case String.trim(params["label"] || "") do
          "" -> attrs
          label -> Map.put(attrs, :label, label)
        end

      case Topics.update(topic, attrs) do
        {:ok, _} -> {:noreply, assign_topics(socket)}
        {:error, changeset} -> {:noreply, put_flash(socket, :error, topic_error(changeset))}
      end
    end)
  end

  @impl true
  def handle_event("keep_topic", %{"id" => id}, socket) do
    with_topic(socket, id, fn topic ->
      {:ok, _} = Topics.keep(topic)
      {:noreply, assign_topics(socket)}
    end)
  end

  @impl true
  def handle_event("pause_topic", %{"id" => id}, socket) do
    with_topic(socket, id, fn topic ->
      {:ok, _} = Topics.pause(topic)
      {:noreply, assign_topics(socket)}
    end)
  end

  @impl true
  def handle_event("resume_topic", %{"id" => id}, socket) do
    with_topic(socket, id, fn topic ->
      {:ok, _} = Topics.resume(topic)
      {:noreply, assign_topics(socket)}
    end)
  end

  @impl true
  def handle_event("remove_topic", %{"id" => id}, socket) do
    with_topic(socket, id, fn topic ->
      {:ok, _} = Topics.delete(topic)
      {:noreply, assign_topics(socket)}
    end)
  end

  @impl true
  def handle_event("remove_excursion", %{"id" => id}, socket) do
    poet = socket.assigns.poet

    with {id, ""} <- Integer.parse(to_string(id)),
         %{status: "queued"} = excursion <- Topics.get_excursion(poet.id, id),
         {:ok, _} <- Topics.delete_excursion(excursion) do
      {:noreply, assign_topics(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save_user", params, socket) do
    user = socket.assigns.user

    case String.trim(params["name"] || "") do
      "" ->
        {:noreply, socket}

      name ->
        case Accounts.update_user(user, %{name: name}) do
          {:ok, updated} -> {:noreply, socket |> assign(:user, updated) |> assign_credits()}
          {:error, _} -> {:noreply, put_flash(socket, :error, "Could not save your name.")}
        end
    end
  end

  @impl true
  def handle_event("save_poet", params, socket) do
    poet = socket.assigns.poet

    interests = Presets.split_interests(params["interests"])

    # The form auto-saves on every keystroke and the changeset requires a
    # name, so a half-retyped (blank) name keeps the current one instead of
    # flashing an error mid-edit.
    name =
      case String.trim(params["poet_name"] || "") do
        "" -> poet.name
        trimmed -> trimmed
      end

    settings =
      (poet.settings || %{})
      |> Map.put("stay_duration_days", parse_days(params["stay_duration_days"]))
      |> Map.put("telegram_notify", params["telegram_notify"] == "on")
      |> Map.put("verbosity", parse_verbosity(params["verbosity"]))
      # Kept in step with the column so the two don't drift: the column is
      # what reaches the agent every run, this copy is what gets baked into
      # the workspace on the next provision.
      |> Map.put("user_interests", interests)

    attrs = %{
      name: name,
      personality: params["personality"],
      interests: interests,
      is_public: params["is_public"] == "on",
      settings: settings
    }

    case Poets.update_poet(poet, attrs) do
      {:ok, updated} ->
        {:noreply, assign(socket, :poet, updated)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not save settings.")}
    end
  end

  ## Currently reading

  @impl true
  def handle_event("toggle_book", %{"idx" => idx}, socket) do
    case Enum.at(socket.assigns.reading_list, String.to_integer(idx)) do
      nil ->
        {:noreply, socket}

      book ->
        items = reading_items(socket.assigns.poet)

        items =
          if Enum.any?(items, &(&1["title"] == book["title"])),
            do: Enum.reject(items, &(&1["title"] == book["title"])),
            else: items ++ [book]

        {:noreply, save_reading(socket, items)}
    end
  end

  @impl true
  def handle_event("add_book", %{"title" => title}, socket) do
    case String.trim(title) do
      "" ->
        {:noreply, socket}

      title ->
        items = reading_items(socket.assigns.poet)

        if Enum.any?(items, &(&1["title"] == title)),
          do: {:noreply, socket},
          else: {:noreply, save_reading(socket, items ++ [%{"title" => title, "author" => ""}])}
    end
  end

  @impl true
  def handle_event("remove_book", %{"title" => title}, socket) do
    items = socket.assigns.poet |> reading_items() |> Enum.reject(&(&1["title"] == title))
    {:noreply, save_reading(socket, items)}
  end

  @impl true
  def handle_event("compose_book", _params, socket) do
    user = Accounts.get_user!(socket.assigns.user.id)
    poet = socket.assigns.poet

    socket = assign(socket, :user, user)

    case poet && Books.request_composition(user, poet) do
      {:ok, _edition} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{poet.name} is composing your book. It takes a few minutes.")
         # the charge just changed the balance the page shows
         |> assign(:user, Accounts.get_user!(user.id))
         |> assign_credits()
         |> assign_book()}

      {:blocked, reason} ->
        {:noreply, socket |> put_flash(:error, blocker_text(reason, poet)) |> assign_book()}

      nil ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("make_pdf", params, socket) do
    user = Accounts.get_user!(socket.assigns.user.id)
    poet = socket.assigns.poet
    opts = %{page_size: params["page_size"], variant: params["variant"]}

    case poet && Books.request_pdf(user, poet, opts) do
      {:ok, _pdf} ->
        {:noreply,
         socket
         |> assign(:user, user)
         |> put_flash(:info, "Making your PDF. It takes a minute or two.")
         |> assign_book()}

      {:blocked, reason} ->
        {:noreply, socket |> put_flash(:error, pdf_blocker_text(reason, poet)) |> assign_book()}

      nil ->
        {:noreply, socket}
    end
  end

  # The reader's own account deletion: the same purge an admin runs, behind
  # the same guard (the account's email, typed). The session then points at
  # nobody, so signing out is all that is left to do.
  @impl true
  def handle_event("delete_account", %{"confirm_email" => typed}, socket) do
    case Accounts.Purge.purge(socket.assigns.user.id, typed) do
      {:ok, _summary} ->
        {:noreply, redirect(socket, to: ~p"/auth/logout")}

      {:error, :email_mismatch} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "That is not this account's email address. Nothing was deleted."
         )}

      {:error, _} ->
        {:noreply,
         put_flash(socket, :error, "The account could not be deleted just now. Please try again.")}
    end
  end

  @impl true
  def handle_event("save_to_drive", %{"id" => id}, socket) do
    user = Accounts.get_user!(socket.assigns.user.id)

    with {pdf_id, ""} <- Integer.parse(id),
         %{} = pdf <- Books.get_owned_pdf(user, pdf_id) do
      case Books.save_pdf_to_drive(user, pdf) do
        {:ok, _} ->
          {:noreply, socket |> assign(:user, user) |> assign_book()}

        # The iOS app cannot be redirected into Google's consent screen (a
        # web view is refused there): the page is told to run the connect in
        # the system sign-in sheet instead (native.js, "native:connect").
        {:error, :not_connected} when socket.assigns.native_app ->
          {:noreply, push_event(socket, "native:connect", %{feature: "drive", pdf: pdf.id})}

        {:error, :not_connected} ->
          {:noreply, redirect(socket, to: ~p"/journal/book/drive/connect?#{[pdf: pdf.id]}")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "That PDF cannot be saved right now.")}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("disconnect_drive", _params, socket) do
    user = Accounts.get_user!(socket.assigns.user.id)
    {:ok, user} = TravelingPoet.GoogleDrive.disconnect(user)

    {:noreply,
     socket
     |> assign(:user, user)
     |> put_flash(:info, "Google Drive disconnected. Files already saved there stay yours.")
     |> assign_book()}
  end

  @impl true
  def handle_event("switch_mode", %{"mode" => mode}, socket) when mode in ["wander", "scout"] do
    poet = socket.assigns.poet
    pending = Enum.count(socket.assigns.stops, &is_nil(&1.visited_at))

    cond do
      Poet.mode(poet) == mode ->
        {:noreply, socket}

      mode == "scout" and pending == 0 ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Add at least one itinerary stop below before switching to Trip Scout."
         )}

      true ->
        {:ok, updated} =
          Poets.update_poet(poet, %{settings: Map.put(poet.settings || %{}, "mode", mode)})

        # The mission (and its model) is baked into the sprite at provision
        # time — repack in the background; keys/tokens are reused so nothing
        # else is disturbed.
        Provisioner.provision_in_background(socket.assigns.user)

        {:noreply,
         socket
         |> assign(:poet, updated)
         |> put_flash(:info, "Your poet is repacking for the new mission — ready in ~2 minutes.")}
    end
  end

  @impl true
  def handle_event("search_stop", %{"query" => query}, socket) do
    case String.trim(query) do
      "" ->
        {:noreply, socket}

      q ->
        case TravelingPoet.Geocoder.Limiter.search(q) do
          {:ok, results} ->
            {:noreply,
             socket
             |> assign(:stop_query, q)
             |> assign(:stop_results, results)
             |> assign(:stop_error, if(results == [], do: "No places found."))}

          {:error, reason} ->
            {:noreply, assign(socket, :stop_error, "Search failed: #{reason}")}
        end
    end
  end

  @impl true
  def handle_event("add_stop", %{"idx" => idx}, socket) do
    with result when not is_nil(result) <-
           Enum.at(socket.assigns.stop_results, String.to_integer(idx)),
         {:ok, _} <- Poets.add_stop(socket.assigns.poet.id, result) do
      {:noreply,
       socket
       |> assign(:stops, Poets.list_stops(socket.assigns.poet.id))
       |> assign(:stop_results, [])
       |> assign(:stop_query, "")}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("release_hold", _params, socket) do
    {:ok, poet} = Poets.release_hold(socket.assigns.poet)

    {:noreply,
     socket
     |> assign(:poet, poet)
     |> put_flash(:info, "#{poet.name} is free to move on with the next run.")}
  end

  @impl true
  def handle_event("remove_stop", %{"id" => id}, socket) do
    poet = socket.assigns.poet

    case Poets.remove_stop(poet.id, String.to_integer(id)) do
      {:ok, %{trip_id: trip_id}} when is_integer(trip_id) ->
        TravelingPoet.Trips.after_stop_removed(poet, trip_id)

      _ ->
        :ok
    end

    {:noreply, socket |> assign(:stops, Poets.list_stops(poet.id)) |> assign_trips()}
  end

  @impl true
  def handle_info({:telegram_paired, _} = msg, socket),
    do: TravelingPoetWeb.TelegramPairing.handle_info(msg, socket)

  @impl true
  def handle_info({:credits_updated, _balance}, socket) do
    {:noreply,
     socket
     |> assign(:user, Accounts.get_user!(socket.assigns.user.id))
     |> assign_credits()
     |> assign_book()}
  end

  @impl true
  def handle_info({:book_edition_updated, _edition_id}, socket) do
    {:noreply, assign_book(socket)}
  end

  @impl true
  def handle_info({:book_pdf_updated, _pdf_id}, socket) do
    {:noreply, assign_book(socket)}
  end

  @impl true
  def handle_info({:trips_updated} = msg, socket),
    do: TravelingPoetWeb.TripSuggestions.handle_info(msg, socket)

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp assign_credits(socket) do
    user = socket.assigns.user
    poet = socket.assigns.poet

    socket
    |> assign(:current_user, user)
    |> assign(:balance, Credits.balance(user))
    |> assign(:runway, Credits.runway_days(user, poet))
    |> assign(:credits_low, Credits.low?(user, poet))
    |> assign(:credits_exhausted, Credits.exhausted?(user, poet))
    |> assign(:transactions, Credits.list_transactions(user, 10))
  end

  defp runway_text(nil), do: "Unlimited — this account is exempt from credits."
  defp runway_text(days) when days < 1, do: "Not enough for tomorrow's entry."

  defp runway_text(days),
    do:
      "≈ #{trunc(days)} #{if trunc(days) == 1, do: "day", else: "days"} of travel at your poet's pace."

  defp tx_label("grant_signup"), do: "Welcome credits"
  defp tx_label("grant_referral"), do: "Referral bonus"
  defp tx_label("grant_grandfather"), do: "Early traveler bonus"
  defp tx_label("grant_admin"), do: "Bonus credits"
  defp tx_label("purchase"), do: "Purchase"
  defp tx_label("debit_daily_run"), do: "Daily journey"
  defp tx_label("debit_book_compose"), do: "Composed book"
  defp tx_label("purchase_refund"), do: "Purchase refunded"
  defp tx_label("refund"), do: "Refund"
  defp tx_label("admin_adjust"), do: "Adjustment"
  defp tx_label(other), do: other

  defp blocker_text(:empty, poet), do: "#{poet.name} has no published pages to bind yet."
  defp blocker_text(:no_sprite, poet), do: "#{poet.name} is still setting out. Try again soon."
  defp blocker_text(:already_composing, poet), do: "#{poet.name} is already composing your book."
  defp blocker_text(:daily_cap, _poet), do: "That is enough books for today. Try again tomorrow."

  defp blocker_text(:insufficient_credits, _poet),
    do: "Not enough credits for a composed edition. Top up above."

  defp blocker_text(:poet_busy, poet),
    do: "#{poet.name} is in the middle of something. Try again in a few minutes."

  defp pdf_blocker_text(:pdf_disabled, _poet), do: "PDFs are not available yet."
  defp pdf_blocker_text(:empty, poet), do: "#{poet.name} has no published pages to print yet."
  defp pdf_blocker_text(:no_sprite, poet), do: "#{poet.name} is still setting out."
  defp pdf_blocker_text(:already_rendering, _poet), do: "A PDF is already being made."

  defp pdf_blocker_text(:daily_cap, _poet),
    do: "That is enough PDFs for today. Try again tomorrow."

  defp pdf_blocker_text(:poet_busy, poet),
    do: "#{poet.name} is composing your book. Make the PDF once it is done."

  attr :pdf, :map, required: true
  attr :connected, :boolean, required: true

  # Save to Drive, as far as this PDF has got: saved (open it), saving,
  # the grant gone (reconnect), failed (try again), or not yet.
  defp drive_save(assigns) do
    ~H"""
    <span class="ml-2" id="drive-save">
      <a
        :if={@pdf.drive_status == "saved" && @pdf.drive_web_link}
        href={@pdf.drive_web_link}
        target="_blank"
        rel="noopener noreferrer"
        class="link"
        id="drive-open"
      >
        Open in Google Drive
      </a>
      <span :if={@pdf.drive_status == "saving"} class="opacity-70" id="drive-saving">
        <span class="loading loading-dots loading-xs align-middle"></span> Saving to Google Drive
      </span>
      <a
        :if={@pdf.drive_status == "failed" && @pdf.drive_error == "reconnect"}
        href={~p"/journal/book/drive/connect?#{[pdf: @pdf.id]}"}
        class="link text-warning"
        id="drive-reconnect"
      >
        Reconnect Google Drive to save it
      </a>
      <button
        :if={
          @pdf.drive_status in [nil, "failed"] &&
            !(@pdf.drive_status == "failed" && @pdf.drive_error == "reconnect")
        }
        type="button"
        phx-click="save_to_drive"
        phx-value-id={@pdf.id}
        class="link"
        id="drive-save-button"
      >
        {if @pdf.drive_status == "failed",
          do: "Saving to Drive failed. Try again",
          else: "Save to Google Drive"}
      </button>
    </span>
    """
  end

  defp megabytes(nil), do: ""
  defp megabytes(bytes), do: :erlang.float_to_binary(bytes / 1_000_000, decimals: 1) <> " MB"

  defp size_label("a5"), do: "A5"
  defp size_label("a4"), do: "A4"
  defp size_label("letter"), do: "Letter"
  defp size_label(other), do: other

  defp signed(milli) when milli >= 0, do: "+" <> Credits.format(milli)
  defp signed(milli), do: "−" <> Credits.format(-milli)

  defp book_status(%{edition: %{status: "composing"}}), do: :composing
  defp book_status(%{edition: %{status: "ready"}}), do: :ready
  defp book_status(%{edition: %{status: "failed"}}), do: :failed
  defp book_status(_book), do: :none

  defp credit_word(1000), do: "credit"
  defp credit_word(_milli), do: "credits"

  defp dollars(cents),
    do: "$#{:erlang.float_to_binary(cents / 100, decimals: 2) |> String.replace(~r/\.00$/, "")}"

  defp reading_items(poet), do: get_in(poet.currently_reading || %{}, ["items"]) || []

  defp save_reading(socket, items) do
    case Poets.update_poet(socket.assigns.poet, %{currently_reading: %{"items" => items}}) do
      {:ok, updated} -> assign(socket, :poet, updated)
      {:error, _} -> put_flash(socket, :error, "Could not save the reading list.")
    end
  end

  # Indices of the curated books the poet is reading (for the chips) and the
  # free-text ones that aren't on the curated list.
  defp selected_book_indices(poet, reading_list) do
    titles = poet |> reading_items() |> MapSet.new(& &1["title"])

    reading_list
    |> Enum.with_index()
    |> Enum.filter(fn {book, _} -> MapSet.member?(titles, book["title"]) end)
    |> MapSet.new(fn {_, idx} -> idx end)
  end

  defp custom_books(poet, reading_list) do
    curated = MapSet.new(reading_list, & &1["title"])
    poet |> reading_items() |> Enum.reject(&MapSet.member?(curated, &1["title"]))
  end

  defp parse_days(str) do
    case Integer.parse(to_string(str)) do
      {n, _} when n in 1..30 -> n
      _ -> 3
    end
  end

  defp parse_verbosity(v) when v in ["brief", "balanced", "expansive"], do: v
  defp parse_verbosity(_), do: "balanced"

  defp with_topic(socket, id, fun) do
    poet = socket.assigns.poet

    with {id, ""} <- Integer.parse(to_string(id)),
         %Topic{} = topic <- Topics.get(poet.id, id) do
      fun.(topic)
    else
      _ -> {:noreply, socket}
    end
  end

  defp parse_kind(kind) when kind in ["professional", "personal"], do: kind
  defp parse_kind(_), do: nil

  defp parse_cadence(str, current) do
    case Integer.parse(to_string(str)) do
      {n, _} when n in 3..30 -> n
      _ -> current
    end
  end

  defp topic_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
    |> then(&"Could not save the topic: #{&1}.")
  end

  defp cadence_options,
    do: [{5, "every 5 days"}, {7, "every week"}, {10, "every 10 days"}, {14, "every two weeks"}]

  defp kind_options,
    do: [{"", "not sure"}, {"professional", "work or study"}, {"personal", "passion"}]

  defp topic_status_label(%Topic{status: "proposed"}), do: "proposed by your poet"
  defp topic_status_label(%Topic{status: "paused"}), do: "paused"
  defp topic_status_label(%Topic{source: "chat"}), do: "from chat"
  defp topic_status_label(%Topic{source: "ask"}), do: "from your answer"
  defp topic_status_label(_), do: nil

  # "last excursion Sep 12, next in 3 days" for an active topic; nothing for
  # the others (a paused topic has no next, a proposal is not yet followed).
  defp topic_schedule(%Topic{status: "active"} = topic, poet_name) do
    last =
      case Topics.last_excursion_on(topic) do
        nil -> "no excursion yet"
        date -> "last excursion " <> Calendar.strftime(date, "%b %-d")
      end

    next =
      case Topics.days_until_due(topic) do
        :due -> "next on the first day #{poet_name} stays put"
        1 -> "next in a day"
        n -> "next in #{n} days"
      end

    last <> ", " <> next
  end

  defp topic_schedule(_topic, _poet_name), do: nil

  defp verbosity_options do
    [
      {"brief", "Brief — short postcards, a few lines and a poem"},
      {"balanced", "Balanced — a paragraph or two per section"},
      {"expansive", "Expansive — full travel-journal essays"}
    ]
  end

  attr :sections, :list, required: true

  @doc """
  The side menu: one link per section, sticky beside the page on a wide
  screen, a row of chips above it on a phone. The hook marks the section
  being read.
  """
  def settings_nav(assigns) do
    ~H"""
    <nav class="settings-nav" id="settings-nav" phx-hook="SettingsNav" phx-update="ignore">
      <a :for={{id, label} <- @sections} href={"##{id}"} data-section={id}>{label}</a>
    </nav>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :note, :string, default: nil
  slot :inner_block, required: true

  @doc "One card of settings, with the heading the side menu points at."
  def settings_section(assigns) do
    ~H"""
    <section class="settings-section" id={@id}>
      <div class="settings-section-head">
        <h2>{@title}</h2>
        <p :if={@note}>{@note}</p>
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  # The menu's order is the page's order.
  defp nav_sections(poet) do
    [
      {"poet", poet.name},
      {"journey", "Journey"},
      {"trips", "Trips"},
      {"book", "Your book"},
      {"topics", "Topics"},
      {"learned", "Learned"},
      {"credits", "Credits"},
      {"notifications", "Notifications"},
      {"account", "Account"}
    ]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={assigns[:current_user]}
      credits_low={assigns[:credits_low]}
      active_tab={:settings}
    >
      <div class="mx-auto max-w-5xl px-4 py-8">
        <div class="flex items-center justify-between mb-6">
          <h1 class="text-2xl font-semibold">Settings</h1>
          <.link navigate={~p"/journal"} class="btn btn-ghost btn-sm">← Journal</.link>
        </div>

        <div :if={@poet} class="settings-layout">
          <.settings_nav sections={nav_sections(@poet)} />

          <div class="settings-main">
            <.settings_section id="poet" title={@poet.name} note="Changes save automatically.">
              <form id="poet-settings-form" phx-change="save_poet" class="space-y-4">
                <label class="block">
                  <span class="text-sm font-medium">Poet's name</span>
                  <input
                    type="text"
                    name="poet_name"
                    phx-debounce="750"
                    value={@poet.name}
                    class="input input-bordered w-full mt-1"
                  />
                  <span class="text-xs opacity-50">
                    Shows in the journal right away; the poet's own introduction updates on
                    the next repack, and the journal link keeps its current address.
                  </span>
                </label>

                <label class="block">
                  <span class="text-sm font-medium">{@poet.name}'s personality</span>
                  <textarea
                    name="personality"
                    phx-debounce="750"
                    class="textarea textarea-bordered w-full mt-1"
                  >{@poet.personality}</textarea>
                </label>

                <label class="block">
                  <span class="text-sm font-medium">What you want {@poet.name} to look for</span>
                  <input
                    type="text"
                    name="interests"
                    phx-debounce="750"
                    value={Enum.join(@poet.interests || [], ", ")}
                    placeholder="street food, bridges, hidden gardens"
                    class="input input-bordered w-full mt-1"
                  />
                  <span class="text-xs opacity-50">
                    Comma separated. Takes effect on tomorrow's entry.
                  </span>
                </label>

                <label class="block">
                  <span class="text-sm font-medium">Days to stay in each place</span>
                  <input
                    type="number"
                    name="stay_duration_days"
                    min="1"
                    max="30"
                    value={Map.get(@poet.settings || %{}, "stay_duration_days", 3)}
                    phx-debounce="500"
                    class="input input-bordered w-24 mt-1"
                  />
                </label>

                <p :if={@poet.hold_until} class="text-sm flex items-center gap-2">
                  <span>
                    Staying put through {Calendar.strftime(@poet.hold_until, "%B %-d")}, as you asked in chat.
                  </span>
                  <button type="button" phx-click="release_hold" class="btn btn-ghost btn-xs">
                    Let it move on
                  </button>
                </p>

                <label class="block">
                  <span class="text-sm font-medium">Journal chattiness</span>
                  <select name="verbosity" class="select select-bordered w-full mt-1">
                    <option
                      :for={{value, label} <- verbosity_options()}
                      value={value}
                      selected={Map.get(@poet.settings || %{}, "verbosity", "balanced") == value}
                    >
                      {label}
                    </option>
                  </select>
                </label>

                <label class="flex items-center gap-3">
                  <input
                    type="checkbox"
                    name="is_public"
                    class="toggle toggle-primary"
                    checked={@poet.is_public}
                  />
                  <span>
                    <b>Public journal</b>
                    <span class="block text-sm opacity-60">
                      Show {@poet.name} on the world map; anyone can read the journal
                    </span>
                  </span>
                </label>

                <label class="flex items-center gap-3">
                  <input
                    type="checkbox"
                    name="telegram_notify"
                    class="toggle"
                    checked={Map.get(@poet.settings || %{}, "telegram_notify", true)}
                  />
                  <span>Telegram note when a new entry is published</span>
                </label>
              </form>

              <div class="mt-5">
                <span class="text-sm font-medium">What {@poet.name} is reading</span>
                <div class="mt-2">
                  <.book_chips
                    books={@reading_list}
                    selected={selected_book_indices(@poet, @reading_list)}
                    event="toggle_book"
                  />
                </div>
                <ul :if={custom_books(@poet, @reading_list) != []} class="mt-2 space-y-1">
                  <li
                    :for={book <- custom_books(@poet, @reading_list)}
                    class="flex items-center gap-2 text-sm"
                  >
                    <span class="flex-1">{book["title"]}</span>
                    <button
                      type="button"
                      phx-click="remove_book"
                      phx-value-title={book["title"]}
                      class="btn btn-ghost btn-xs"
                      title="Remove"
                    >
                      ✕
                    </button>
                  </li>
                </ul>
              </div>

              <form id="add-book-form" phx-submit="add_book" class="flex gap-2 mt-3">
                <input
                  type="text"
                  name="title"
                  class="input input-bordered input-sm flex-1"
                  placeholder="Add another book for the road…"
                />
                <button type="submit" class="btn btn-sm">Add</button>
              </form>
            </.settings_section>

            <.settings_section id="journey" title="Journey">
              <div class="flex gap-2 mb-3">
                <button
                  phx-click="switch_mode"
                  phx-value-mode="wander"
                  class={["btn btn-sm flex-1", Poet.mode(@poet) == "wander" && "btn-primary"]}
                >
                  🧭 Wanderer
                </button>
                <button
                  phx-click="switch_mode"
                  phx-value-mode="scout"
                  class={["btn btn-sm flex-1", Poet.mode(@poet) == "scout" && "btn-primary"]}
                >
                  🗺️ Trip Scout
                </button>
              </div>
              <p class="text-xs opacity-60 mb-4">
                Switching missions repacks your poet (~2 minutes). Trip Scouts follow the
                itinerary below, in order, on a more careful model.
              </p>

              <h3 class="text-sm font-medium mb-2">
                Trip itinerary {if Poet.mode(@poet) != "scout", do: "(used in Trip Scout mode)"}
              </h3>
              <form phx-submit="search_stop" class="flex gap-2 mb-2">
                <input
                  type="text"
                  name="query"
                  value={@stop_query}
                  class="input input-bordered input-sm flex-1"
                  placeholder="Add a place…"
                />
                <button type="submit" class="btn btn-sm">Search</button>
              </form>
              <p :if={@stop_error} class="text-error text-xs mb-2">{@stop_error}</p>
              <div :if={@stop_results != []} class="space-y-1 mb-2">
                <button
                  :for={{result, idx} <- Enum.with_index(@stop_results)}
                  phx-click="add_stop"
                  phx-value-idx={idx}
                  class="btn btn-outline btn-xs w-full justify-start text-left normal-case"
                >
                  + {result.place_name}
                </button>
              </div>
              <ol :if={@stops != []} class="space-y-1 mb-2">
                <li
                  :for={stop <- @stops}
                  class="flex items-center gap-2 text-sm p-2 rounded-lg bg-base-200"
                >
                  <span>{if stop.visited_at, do: "✓", else: "#{stop.position + 1}."}</span>
                  <span class={["flex-1", stop.visited_at && "opacity-50 line-through"]}>
                    {stop.place_name}
                    <span :if={stop.source == "chat"} class="badge badge-ghost badge-xs ml-1">
                      asked in chat
                    </span>
                    <span :if={stop.source == "trip"} class="badge badge-ghost badge-xs ml-1">
                      for your trip
                    </span>
                  </span>
                  <button
                    :if={is_nil(stop.visited_at)}
                    phx-click="remove_stop"
                    phx-value-id={stop.id}
                    class="btn btn-ghost btn-xs"
                  >
                    ✕
                  </button>
                </li>
              </ol>
              <p :if={@stops == []} class="text-xs opacity-60 mb-2">No stops yet.</p>
            </.settings_section>

            <.settings_section
              :if={@trips.enabled?}
              id="trips"
              title="Trips"
              note="Trips on your calendar, scouted before you go."
            >
              <.trip_settings trips={@trips} user={@user} poet={@poet} />
            </.settings_section>

            <.settings_section id="book" title="Your book">
              <p class="text-sm opacity-70 mb-3">
                The whole journal as one printable notebook: a chapter for every place,
                a table of contents, every drawing with what it was drawn from, every
                source written out. Print it or save it as a PDF from your browser. Free.
              </p>
              <a
                href={~p"/journal/book"}
                target="_blank"
                class="btn btn-outline btn-sm"
                id="open-book"
              >
                <.icon name="hero-book-open" class="size-4" /> Open the book
              </a>

              <div :if={@book && @book.pdf_enabled && @book.chapters > 0} class="mt-4" id="book-pdf">
                <h3 class="text-sm font-medium mb-1">A PDF to keep</h3>
                <p class="text-sm opacity-70 mb-2">
                  The book as a PDF file, made on {@poet.name}'s own machine, ready to download,
                  print or share. Free.
                </p>

                <div :if={@book.last_ready_pdf} class="text-sm mb-2" id="book-pdf-ready">
                  <a
                    href={~p"/journal/book/pdf/#{@book.last_ready_pdf.id}"}
                    class="link font-medium"
                    id="book-pdf-download"
                  >
                    <.icon name="hero-arrow-down-tray" class="size-4" /> Download the PDF
                  </a>
                  <.drive_save pdf={@book.last_ready_pdf} connected={@book.drive_connected} />
                  <span class="opacity-60 block">
                    ({megabytes(@book.last_ready_pdf.byte_size)}, {@book.last_ready_pdf.pages} pages, {size_label(
                      @book.last_ready_pdf.page_size
                    )}{if @book.last_ready_pdf.variant == "composed", do: ", composed"}, made {Calendar.strftime(
                      @book.last_ready_pdf.rendered_at,
                      "%b %-d"
                    )})
                  </span>
                </div>

                <p
                  :if={match?(%{status: "rendering"}, @book.pdf)}
                  class="text-sm mb-2"
                  id="book-pdf-rendering"
                >
                  <span class="loading loading-dots loading-xs align-middle"></span>
                  Making your PDF. The first one takes a couple of minutes longer while {@poet.name}'s machine gets ready.
                </p>

                <p
                  :if={match?(%{status: "failed"}, @book.pdf)}
                  class="text-sm text-warning mb-2"
                  id="book-pdf-failed"
                >
                  The last PDF did not come out. You can try again.
                </p>

                <form
                  :if={!match?(%{status: "rendering"}, @book.pdf)}
                  phx-submit="make_pdf"
                  id="make-pdf-form"
                  class="flex flex-wrap items-end gap-2"
                >
                  <label class="text-xs">
                    <span class="block opacity-70 mb-1">Paper</span>
                    <select name="page_size" class="select select-sm">
                      <option value="a5">A5</option>
                      <option value="a4">A4</option>
                      <option value="letter">Letter</option>
                    </select>
                  </label>
                  <label :if={@book.has_composed} class="text-xs">
                    <span class="block opacity-70 mb-1">Edition</span>
                    <select name="variant" class="select select-sm">
                      <option value="composed">Composed</option>
                      <option value="plain">As written</option>
                    </select>
                  </label>
                  <button
                    type="submit"
                    class="btn btn-sm btn-outline"
                    disabled={@book.pdf_blocker not in [nil, :poet_busy]}
                    id="make-pdf-button"
                  >
                    {if @book.last_ready_pdf, do: "Make a new PDF", else: "Make the PDF"}
                  </button>
                </form>
                <p :if={@book.pdf_blocker == :daily_cap} class="text-xs opacity-70 mt-1">
                  That is enough PDFs for today. Try again tomorrow.
                </p>
                <button
                  :if={@book.drive_connected}
                  type="button"
                  phx-click="disconnect_drive"
                  class="link text-xs opacity-60 mt-2 block"
                  id="disconnect-drive"
                >
                  Disconnect Google Drive
                </button>
                <p :if={@book.pdf_blocker == :no_sprite} class="text-xs opacity-70 mt-1">
                  {@poet.name} is still setting out.
                </p>
              </div>

              <div :if={@book && @book.chapters > 0} class="mt-4" id="compose-book">
                <h3 class="text-sm font-medium mb-1">A composed edition</h3>
                <p class="text-sm opacity-70 mb-2">
                  {@poet.name} writes the words around the journal: a dedication to you,
                  a foreword, an opening for each place, an epilogue, and a few of its own
                  lines set on pages of their own. The journal itself is not changed.
                </p>

                <p :if={book_status(@book) == :composing} class="text-sm" id="book-composing">
                  <span class="loading loading-dots loading-xs align-middle"></span>
                  {@poet.name} is composing your book. It takes a few minutes; this page
                  updates when it is done.
                </p>

                <p :if={book_status(@book) == :ready} class="text-sm mb-2" id="book-ready">
                  Composed on {Calendar.strftime(@book.edition.composed_at, "%B %-d")}.
                  It is in the book now.
                </p>

                <p
                  :if={book_status(@book) == :failed}
                  class="text-sm text-warning mb-2"
                  id="book-failed"
                >
                  The last composition did not finish, so nothing was charged for it.
                </p>

                <button
                  :if={book_status(@book) != :composing}
                  phx-click="compose_book"
                  class="btn btn-sm btn-primary"
                  disabled={@book.blocker not in [nil, :poet_busy]}
                  id="compose-book-button"
                >
                  {if book_status(@book) == :ready,
                    do: "Compose it again",
                    else: "Ask #{@poet.name} to compose it"}
                  <span class="opacity-80">
                    ({if @book.exempt,
                      do: "free",
                      else: "#{Credits.format(@book.cost)} #{credit_word(@book.cost)}"})
                  </span>
                </button>
                <p
                  :if={@book.blocker == :insufficient_credits}
                  class="text-xs text-warning mt-1"
                >
                  Not enough credits for a composed edition.
                </p>
                <p :if={@book.blocker == :daily_cap} class="text-xs opacity-70 mt-1">
                  That is enough books for today. Try again tomorrow.
                </p>
                <p :if={@book.blocker == :no_sprite} class="text-xs opacity-70 mt-1">
                  {@poet.name} is still setting out.
                </p>
              </div>
            </.settings_section>

            <.settings_section id="topics" title={"Topics " <> @poet.name <> " follows for you"}>
              <p class="text-sm opacity-60 mb-3">
                Beyond places: a field you work in, a passion you keep. Every so often {@poet.name} takes a day off the road for an excursion into one of these, a conference, a festival, a lab, a company, and writes back about it. Tell {@poet.name} in chat, or add one here.
              </p>

              <p :if={@topics == []} class="text-sm opacity-50 mb-2">
                None yet.
              </p>

              <ul class="space-y-2">
                <li
                  :for={topic <- @topics}
                  id={"topic-#{topic.id}"}
                  class={[
                    "p-2 rounded-lg border border-base-200",
                    topic.status == "paused" && "opacity-60"
                  ]}
                >
                  <form
                    id={"topic-form-#{topic.id}"}
                    phx-change="save_topic"
                    phx-value-id={topic.id}
                    class="flex flex-wrap items-center gap-2"
                  >
                    <input type="hidden" name="topic_id" value={topic.id} />
                    <input
                      type="text"
                      name="label"
                      phx-debounce="750"
                      value={topic.label}
                      class="input input-bordered input-sm flex-1 min-w-40"
                    />
                    <select name="kind" class="select select-bordered select-sm">
                      <option
                        :for={{value, label} <- kind_options()}
                        value={value}
                        selected={(topic.kind || "") == value}
                      >
                        {label}
                      </option>
                    </select>
                    <select
                      name="every_days"
                      class="select select-bordered select-sm"
                      disabled={topic.status == "proposed"}
                    >
                      <option
                        :for={{days, label} <- cadence_options()}
                        value={days}
                        selected={topic.every_days == days}
                      >
                        {label}
                      </option>
                    </select>
                  </form>
                  <div class="flex items-center gap-2 mt-1 text-xs opacity-60">
                    <span :if={topic_status_label(topic)}>{topic_status_label(topic)}</span>
                    <span :if={topic_schedule(topic, @poet.name)}>{topic_schedule(topic, @poet.name)}</span>
                    <span :if={topic.evidence["quote"]} class="italic">
                      &ldquo;{topic.evidence["quote"]}&rdquo;
                    </span>
                    <span class="flex-1"></span>
                    <button
                      :if={topic.status == "proposed"}
                      type="button"
                      phx-click="keep_topic"
                      phx-value-id={topic.id}
                      class="btn btn-primary btn-xs"
                    >
                      Keep
                    </button>
                    <button
                      :if={topic.status == "proposed"}
                      type="button"
                      phx-click="remove_topic"
                      phx-value-id={topic.id}
                      class="btn btn-ghost btn-xs"
                    >
                      Not this
                    </button>
                    <button
                      :if={topic.status == "active"}
                      type="button"
                      phx-click="pause_topic"
                      phx-value-id={topic.id}
                      class="btn btn-ghost btn-xs"
                    >
                      Pause
                    </button>
                    <button
                      :if={topic.status == "paused"}
                      type="button"
                      phx-click="resume_topic"
                      phx-value-id={topic.id}
                      class="btn btn-ghost btn-xs"
                    >
                      Resume
                    </button>
                    <button
                      :if={topic.status != "proposed"}
                      type="button"
                      phx-click="remove_topic"
                      phx-value-id={topic.id}
                      class="btn btn-ghost btn-xs"
                      title="Remove"
                    >
                      ✕
                    </button>
                  </div>
                </li>
              </ul>

              <div :if={@queued_excursions != []} class="mt-3">
                <h3 class="text-sm font-medium mb-1">Asked for in chat</h3>
                <ul id="queued-excursions" class="space-y-1">
                  <li
                    :for={x <- @queued_excursions}
                    id={"excursion-#{x.id}"}
                    class="flex items-center gap-2 text-sm p-2 rounded-lg bg-base-200"
                  >
                    <span class="flex-1">
                      {x.requested_destination}
                      <span class="opacity-60">for {x.topic.label}</span>
                    </span>
                    <span class="text-xs opacity-60">on the next day {@poet.name} stays put</span>
                    <button
                      type="button"
                      phx-click="remove_excursion"
                      phx-value-id={x.id}
                      class="btn btn-ghost btn-xs"
                      title="Remove"
                    >
                      ✕
                    </button>
                  </li>
                </ul>
              </div>

              <form id="add-topic-form" phx-submit="add_topic" class="flex gap-2 mt-3">
                <input
                  type="text"
                  name="label"
                  class="input input-bordered input-sm flex-1"
                  placeholder="Add a topic, like kit airplanes or embodied minds"
                />
                <select name="kind" class="select select-bordered select-sm">
                  <option :for={{value, label} <- kind_options()} value={value}>{label}</option>
                </select>
                <button type="submit" class="btn btn-sm">Add</button>
              </form>
            </.settings_section>

            <.settings_section id="learned" title={"What " <> @poet.name <> " has learned about you"}>
              <p class="text-sm opacity-60 mb-3">
                Picked up from what you tap under an entry and what you say in chat. {@poet.name} applies these on its own — remove anything that isn't right.
              </p>

              <p :if={@learned == []} class="text-sm opacity-50">
                Nothing yet. Answer a question under an entry, or just tell {@poet.name} in chat what you'd rather read about.
              </p>

              <ul class="space-y-2">
                <li
                  :for={pref <- @learned}
                  class="flex items-start gap-2 p-2 rounded-lg border border-base-200"
                >
                  <div class="flex-1">
                    <div class="text-sm">
                      <span :if={pref.polarity == "avoid"} class="opacity-60">less: </span>{pref.label}
                    </div>
                    <div class="text-xs opacity-50">
                      {source_label(pref.source)}
                      <span :if={pref.weight > 1}>· mentioned {pref.weight}×</span>
                      <span :if={pref.evidence["quote"]} class="italic">
                        · &ldquo;{pref.evidence["quote"]}&rdquo;
                      </span>
                    </div>
                  </div>
                  <button
                    phx-click="dismiss_preference"
                    phx-value-id={pref.id}
                    class="btn btn-ghost btn-xs"
                    title="Remove"
                  >
                    ✕
                  </button>
                </li>
              </ul>

              <details :if={@dismissed != []} class="mt-3">
                <summary class="text-xs opacity-50 cursor-pointer">
                  Removed ({length(@dismissed)})
                </summary>
                <ul class="mt-2 space-y-1">
                  <li :for={pref <- @dismissed} class="flex items-center gap-2 text-sm opacity-60">
                    <span class="flex-1">{pref.label}</span>
                    <button
                      phx-click="restore_preference"
                      phx-value-id={pref.id}
                      class="btn btn-ghost btn-xs"
                    >
                      restore
                    </button>
                  </li>
                </ul>
              </details>
            </.settings_section>

            <.settings_section id="credits" title="Credits">
              <div class="flex items-baseline gap-3">
                <span class="text-3xl font-semibold" id="credits-balance">
                  {Credits.format(@balance)}
                </span>
                <span class="text-sm opacity-60">credits</span>
              </div>
              <p class={["text-sm mt-1", @credits_low && "text-warning"]}>{runway_text(@runway)}</p>
              <p :if={@credits_exhausted} class="text-sm text-error mt-1">
                Your poet is resting until you top up.
              </p>
              <p class="text-xs opacity-60 mt-2 mb-3">
                Each day's journey costs {Credits.format(Credits.daily_run_cost(@poet))}
                {if Poet.mode(@poet) == "scout", do: "credits (Trip Scout)", else: "credit (Wanderer)"};
                chatting and drawings are included. Days spent scouting one of your own
                trips cost the Trip Scout rate.
              </p>

              <%!-- Card checkout, never inside the iOS app: Apple requires its own
                    In-App Purchase for credits there (guideline 3.1.1), and the
                    markup itself must not offer another way to pay. --%>
              <div
                :if={!@native_app}
                id="credit-packs"
                class="grid grid-cols-2 sm:grid-cols-4 gap-2 mb-3"
              >
                <form :for={pack <- @packs} method="post" action={~p"/credits/checkout"}>
                  <input
                    type="hidden"
                    name="_csrf_token"
                    value={Plug.CSRFProtection.get_csrf_token()}
                  />
                  <input type="hidden" name="pack" value={pack.id} />
                  <button type="submit" class="btn btn-outline btn-sm w-full flex-col h-auto py-2">
                    <span class="font-semibold">{pack.credits} credits</span>
                    <span class="text-xs opacity-70">{dollars(pack.cents)}</span>
                  </button>
                </form>
              </div>
              <%!-- In the iOS app the same packs are sold by StoreKit. The hook asks
                    the device for their localized prices, runs the purchase, and
                    posts the signed transaction to /iap/apple/transactions; the
                    balance above updates by itself when the ledger does. --%>
              <div
                :if={@native_app}
                id="apple-credit-packs"
                phx-hook="AppleIAP"
                phx-update="ignore"
                data-products={Jason.encode!(TravelingPoet.Payments.AppleIAP.products())}
                data-account-token={TravelingPoet.Payments.AppleIAP.app_account_token(@user)}
                class="mb-3"
              >
                <div class="grid grid-cols-2 sm:grid-cols-4 gap-2" data-role="packs"></div>
                <p class="text-xs opacity-60 mt-2" data-role="status" aria-live="polite"></p>
              </div>
              <p :if={@payments_mock and !@native_app} class="text-xs text-warning mb-3">
                Payments are in test mode — purchases are mocked and free.
              </p>

              <details :if={@transactions != []} class="text-sm">
                <summary class="cursor-pointer opacity-70">Recent activity</summary>
                <ul class="mt-2 space-y-1">
                  <li :for={tx <- @transactions} class="flex justify-between gap-2">
                    <span>{tx_label(tx.kind)}</span>
                    <span class="opacity-60 text-xs">
                      {Calendar.strftime(tx.inserted_at, "%b %-d")}
                    </span>
                    <span class={["tabular-nums", tx.amount < 0 && "opacity-70"]}>
                      {signed(tx.amount)}
                    </span>
                  </li>
                </ul>
              </details>
            </.settings_section>

            <.settings_section id="notifications" title="Notifications">
              <.push_settings push={@push} poet={@poet} />
              <div class="settings-rule"></div>
              <.telegram_settings telegram={@telegram} user={@user} />
            </.settings_section>

            <.settings_section id="account" title="Account">
              <form id="user-settings-form" phx-change="save_user" class="mb-4">
                <label class="block">
                  <span class="text-sm font-medium">Your name</span>
                  <input
                    type="text"
                    name="name"
                    phx-debounce="750"
                    value={@user.name}
                    class="input input-bordered w-full mt-1"
                  />
                  <span class="text-xs opacity-50">How {@poet.name} addresses you.</span>
                </label>
              </form>

              <a href={~p"/auth/logout"} class="btn btn-ghost btn-sm mt-4">Sign out</a>

              <p class="text-xs opacity-60 mt-4">
                <.link navigate={~p"/privacy"} class="link">Privacy policy</.link>
                · <.link navigate={~p"/terms"} class="link">Terms of service</.link>
                · <.link navigate={~p"/support"} class="link">Support</.link>
              </p>

              <details id="delete-account" class="mt-6 border-t border-base-300 pt-4">
                <summary class="cursor-pointer text-sm text-error">Delete account</summary>
                <div class="mt-3 text-sm space-y-3">
                  <p>
                    This deletes your account and everything in it, now and for good: {if @poet,
                      do: @poet.name,
                      else: "your poet"}, every journal entry and
                    drawing, the trip guide, your chat, your credits, and the connections
                    to Google, Apple and Telegram. A public journal stops being readable.
                    Nothing can be restored afterwards, and unused credits are not refunded.
                  </p>
                  <form id="delete-account-form" phx-submit="delete_account" class="space-y-2">
                    <label class="block">
                      <span class="text-sm">
                        To confirm, type the email address of this account, <b>{@user.email}</b>
                      </span>
                      <input
                        type="email"
                        name="confirm_email"
                        autocomplete="off"
                        autocapitalize="off"
                        spellcheck="false"
                        required
                        class="input input-bordered w-full mt-1"
                      />
                    </label>
                    <button
                      type="submit"
                      class="btn btn-error btn-sm"
                      phx-disable-with="Deleting..."
                    >
                      Delete my account for good
                    </button>
                  </form>
                </div>
              </details>
            </.settings_section>
          </div>
        </div>

        <div :if={is_nil(@poet)} class="max-w-xl">
          <p class="opacity-70">
            No poet yet — <.link navigate={~p"/onboarding"} class="link">set one up</.link>.
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
