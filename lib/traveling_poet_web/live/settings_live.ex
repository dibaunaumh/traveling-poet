defmodule TravelingPoetWeb.SettingsLive do
  use TravelingPoetWeb, :live_view

  import TravelingPoetWeb.PushNotifications, only: [assign_push: 1, push_settings: 1]
  import TravelingPoetWeb.TelegramPairing, only: [assign_telegram: 1, telegram_settings: 1]

  import TravelingPoetWeb.TripSuggestions,
    only: [assign_trips: 1, home_settings: 1, trip_settings: 1]

  import TravelingPoetWeb.PoetComponents
  import TravelingPoetWeb.AffinityComponents, only: [taste_map: 1]
  import TravelingPoetWeb.ShareComponents, only: [invite_actions: 1, invite_text: 1]

  alias TravelingPoet.{
    Accounts,
    Books,
    Credits,
    Geocoder,
    Payments,
    Poets,
    Preferences,
    Provisioner,
    Referrals
  }

  alias TravelingPoet.Poets.{Poet, Presets}
  alias TravelingPoet.Affinity
  alias TravelingPoet.ReaderNote
  alias TravelingPoet.Topics
  alias TravelingPoet.Topics.Topic

  @impl true
  def mount(params, _session, socket) do
    user = socket.assigns.current_user
    poet = Poets.get_poet_by_user(user.id)

    socket =
      if params["purchased"] == "1",
        do: put_flash(socket, :info, dgettext("settings", "Credits added. Happy travels!")),
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
     |> assign(:page_title, dgettext("settings", "Settings"))
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
     |> assign_note()
     |> assign(:understanding, false)
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
        socket |> assign(:topics, []) |> assign(:tastes, %{}) |> assign(:queued_excursions, [])

      poet ->
        {tastes, subjects} = poet.id |> Topics.list() |> Enum.split_with(& &1.domain)

        socket
        |> assign(:topics, subjects)
        |> assign(:tastes, Enum.group_by(tastes, & &1.domain))
        |> assign(:queued_excursions, Topics.list_queued(poet.id))
    end
  end

  # "About you" (card-125): the note, and the lines the poet suggests for it.
  defp assign_note(socket) do
    case socket.assigns.poet do
      nil ->
        socket |> assign(:note, nil) |> assign(:note_suggestions, [])

      poet ->
        socket
        |> assign(:note, ReaderNote.get(poet.id))
        |> assign(:note_suggestions, ReaderNote.pending(poet.id))
    end
  end

  # After a save or an accepted line: read the note and add what it says,
  # off the LiveView process (one model call), then show what was taken.
  defp understand_note(socket) do
    poet_id = socket.assigns.poet.id

    socket
    |> assign(:understanding, true)
    |> start_async(:understand_note, fn -> ReaderNote.understand(poet_id) end)
  end

  defp assign_learned(socket) do
    socket = assign_affinity(socket)

    case socket.assigns.poet do
      nil ->
        socket |> assign(:learned, []) |> assign(:dismissed, [])

      poet ->
        socket
        |> assign(:learned, Preferences.list_active(poet.id))
        |> assign(:dismissed, Preferences.list_dismissed(poet.id))
    end
  end

  # The taste profile: the whole of it for the map, the strongest for the list.
  defp assign_affinity(socket) do
    user = socket.assigns.user
    profile = Affinity.profile(user)

    socket
    |> assign(:affinity, profile)
    |> assign(:affinity_top, Affinity.top(user))
    |> assign(:affinity_dismissed, Affinity.dismissed(user))
  end

  defp understood_any?(understood) when is_map(understood),
    do: Enum.any?(~w(tastes topics avoids), &(Map.get(understood, &1, []) != []))

  defp understood_any?(_), do: false

  defp source_label("tap"), do: dgettext("settings", "you tapped this")
  defp source_label("chat"), do: dgettext("settings", "you said this in chat")
  defp source_label("settings"), do: dgettext("settings", "you set this")
  defp source_label("onboarding"), do: dgettext("settings", "from your setup")
  defp source_label("reaction"), do: dgettext("settings", "from your reaction")
  defp source_label("marker"), do: dgettext("settings", "from your markers")
  defp source_label(_), do: dgettext("settings", "learned")

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
        attrs =
          case parse_domain(params["domain"]) do
            nil -> %{label: label, kind: parse_kind(params["kind"])}
            domain -> %{label: label, domain: domain}
          end

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
          {:ok, updated} ->
            {:noreply, socket |> assign(:user, updated) |> assign_credits()}

          {:error, _} ->
            {:noreply,
             put_flash(socket, :error, dgettext("settings", "Could not save your name."))}
        end
    end
  end

  @impl true
  def handle_event("dismiss_subject", %{"path" => path}, socket) do
    Affinity.dismiss(socket.assigns.user, path)
    {:noreply, assign_affinity(socket)}
  end

  @impl true
  def handle_event("restore_subject", %{"path" => path}, socket) do
    Affinity.restore(socket.assigns.user, path)
    {:noreply, assign_affinity(socket)}
  end

  # A new language needs a full page load: the page's lang and dir sit on
  # <html>, which a LiveView patch never touches.
  @impl true
  def handle_event("set_locale", %{"locale" => locale}, socket) do
    case Accounts.set_locale(socket.assigns.user, locale) do
      {:ok, _} ->
        {:noreply, redirect(socket, to: ~p"/settings#account")}

      {:error, _} ->
        {:noreply,
         put_flash(socket, :error, dgettext("settings", "Could not save that setting."))}
    end
  end

  @impl true
  def handle_event("save_note", %{"text" => text}, socket) do
    case ReaderNote.save(socket.assigns.poet.id, text) do
      {:ok, nil} ->
        {:noreply, assign_note(socket)}

      {:ok, _note} ->
        {:noreply, socket |> assign_note() |> understand_note()}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           dgettext("settings", "Could not save that. Keep it under %{n} characters.",
             n: ReaderNote.Note.max_chars()
           )
         )}
    end
  end

  def handle_event("accept_note_line", %{"id" => id}, socket) do
    case ReaderNote.accept(socket.assigns.poet.id, id) do
      {:ok, _} -> {:noreply, socket |> assign_note() |> understand_note()}
      _ -> {:noreply, assign_note(socket)}
    end
  end

  def handle_event("decline_note_line", %{"id" => id}, socket) do
    ReaderNote.decline(socket.assigns.poet.id, id)
    {:noreply, assign_note(socket)}
  end

  @impl true
  def handle_event("claim_invite", %{"code" => code}, socket) do
    case Referrals.claim(socket.assigns.user, code) do
      {:ok, _referrer} ->
        {:noreply,
         socket
         |> assign(:user, Accounts.get_user!(socket.assigns.user.id))
         |> assign_credits()
         |> put_flash(
           :info,
           dgettext("settings", "Welcome! %{credits} extra credits are yours.",
             credits: Referrals.referral_credits()
           )
         )}

      {:error, :own_code} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           dgettext("settings", "That is your own code. Send it to a friend.")
         )}

      {:error, :not_eligible} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           dgettext("settings", "Invite codes are for new readers in their first week.")
         )}

      {:error, :invalid_code} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           dgettext("settings", "That code does not match anyone's invite.")
         )}
    end
  end

  @impl true
  def handle_event("toggle_email", params, socket) do
    case Accounts.update_user(socket.assigns.user, %{
           email_notify: params["email_notify"] == "true",
           email_full_page: params["email_full_page"] == "true"
         }) do
      {:ok, updated} ->
        {:noreply, assign(socket, :user, updated)}

      {:error, _} ->
        {:noreply,
         put_flash(socket, :error, dgettext("settings", "Could not save that setting."))}
    end
  end

  @impl true
  def handle_event("toggle_reading", params, socket) do
    on = params["reading_signals"] == "true"

    case Accounts.update_user(socket.assigns.user, %{reading_signals: on}) do
      {:ok, updated} ->
        unless on, do: TravelingPoet.Reading.forget(updated)
        {:noreply, socket |> assign(:user, updated) |> assign_affinity()}

      {:error, _} ->
        {:noreply,
         put_flash(socket, :error, dgettext("settings", "Could not save that setting."))}
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
        {:noreply, put_flash(socket, :error, dgettext("settings", "Could not save settings."))}
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
         |> put_flash(
           :info,
           dgettext("settings", "%{poet} is composing your book. It takes a few minutes.",
             poet: poet.name
           )
         )
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
         |> put_flash(:info, dgettext("settings", "Making your PDF. It takes a minute or two."))
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
           dgettext("settings", "That is not this account's email address. Nothing was deleted.")
         )}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           dgettext("settings", "The account could not be deleted just now. Please try again.")
         )}
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
          {:noreply,
           put_flash(socket, :error, dgettext("settings", "That PDF cannot be saved right now."))}
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
     |> put_flash(
       :info,
       dgettext("settings", "Google Drive disconnected. Files already saved there stay yours.")
     )
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
           dgettext(
             "settings",
             "Add at least one itinerary stop below before switching to Trip Scout."
           )
         )}

      true ->
        {:ok, updated} =
          Poets.update_poet(poet, %{settings: Map.put(poet.settings || %{}, "mode", mode)})

        # The mission (and its model) live in the sprite's config and persona
        # files: repack them in the background, gateway stopped first
        Provisioner.repack_in_background(socket.assigns.user)

        {:noreply,
         socket
         |> assign(:poet, updated)
         |> put_flash(
           :info,
           dgettext(
             "settings",
             "Your poet is repacking for the new mission — ready in ~2 minutes."
           )
         )}
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
             |> assign(
               :stop_error,
               if(results == [], do: dgettext("settings", "No places found."))
             )}

          {:error, reason} ->
            {:noreply,
             assign(
               socket,
               :stop_error,
               dgettext("settings", "Search failed: %{reason}", reason: reason)
             )}
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
     |> put_flash(
       :info,
       dgettext("settings", "%{poet} is free to move on with the next run.", poet: poet.name)
     )}
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
    |> assign_invite()
  end

  # Invite friends (card-126): the reader's link, who came through it, and
  # the code field a new reader who installed the app (and so lost the link)
  # can still use in their first week.
  defp assign_invite(socket) do
    user = socket.assigns.user
    code = Referrals.code_for(user)

    socket
    |> assign(:invite_code, code)
    |> assign(:invite_url, url(~p"/i/#{code}"))
    |> assign(:invite_stats, Referrals.stats(user))
    |> assign(:can_claim_invite, Referrals.can_claim?(user))
    |> assign(:invited_by, user.referred_by_id && Accounts.get_user(user.referred_by_id))
  end

  defp runway_text(nil),
    do: dgettext("settings", "Unlimited — this account is exempt from credits.")

  defp runway_text(days) when days < 1,
    do: dgettext("settings", "Not enough for tomorrow's entry.")

  defp runway_text(days),
    do:
      dngettext(
        "settings",
        "≈ %{count} day of travel at your poet's pace.",
        "≈ %{count} days of travel at your poet's pace.",
        trunc(days)
      )

  defp tx_label("grant_signup"), do: dgettext("settings", "Welcome credits")
  defp tx_label("grant_referral"), do: dgettext("settings", "Referral bonus")
  defp tx_label("grant_grandfather"), do: dgettext("settings", "Early traveler bonus")
  defp tx_label("grant_admin"), do: dgettext("settings", "Bonus credits")
  defp tx_label("purchase"), do: dgettext("settings", "Purchase")
  defp tx_label("debit_daily_run"), do: dgettext("settings", "Daily journey")
  defp tx_label("debit_book_compose"), do: dgettext("settings", "Composed book")
  defp tx_label("purchase_refund"), do: dgettext("settings", "Purchase refunded")
  defp tx_label("refund"), do: dgettext("settings", "Refund")
  defp tx_label("admin_adjust"), do: dgettext("settings", "Adjustment")
  defp tx_label(other), do: other

  defp blocker_text(:empty, poet),
    do: dgettext("settings", "%{poet} has no published pages to bind yet.", poet: poet.name)

  defp blocker_text(:no_sprite, poet),
    do: dgettext("settings", "%{poet} is still setting out. Try again soon.", poet: poet.name)

  defp blocker_text(:already_composing, poet),
    do: dgettext("settings", "%{poet} is already composing your book.", poet: poet.name)

  defp blocker_text(:daily_cap, _poet),
    do: dgettext("settings", "That is enough books for today. Try again tomorrow.")

  defp blocker_text(:insufficient_credits, _poet),
    do: dgettext("settings", "Not enough credits for a composed edition. Top up above.")

  defp blocker_text(:poet_busy, poet),
    do:
      dgettext("settings", "%{poet} is in the middle of something. Try again in a few minutes.",
        poet: poet.name
      )

  defp pdf_blocker_text(:pdf_disabled, _poet),
    do: dgettext("settings", "PDFs are not available yet.")

  defp pdf_blocker_text(:empty, poet),
    do: dgettext("settings", "%{poet} has no published pages to print yet.", poet: poet.name)

  defp pdf_blocker_text(:no_sprite, poet),
    do: dgettext("settings", "%{poet} is still setting out.", poet: poet.name)

  defp pdf_blocker_text(:already_rendering, _poet),
    do: dgettext("settings", "A PDF is already being made.")

  defp pdf_blocker_text(:daily_cap, _poet),
    do: dgettext("settings", "That is enough PDFs for today. Try again tomorrow.")

  defp pdf_blocker_text(:poet_busy, poet),
    do:
      dgettext("settings", "%{poet} is composing your book. Make the PDF once it is done.",
        poet: poet.name
      )

  attr :pdf, :map, required: true
  attr :connected, :boolean, required: true

  # Save to Drive, as far as this PDF has got: saved (open it), saving,
  # the grant gone (reconnect), failed (try again), or not yet.
  defp drive_save(assigns) do
    ~H"""
    <span class="ms-2" id="drive-save">
      <a
        :if={@pdf.drive_status == "saved" && @pdf.drive_web_link}
        href={@pdf.drive_web_link}
        target="_blank"
        rel="noopener noreferrer"
        class="link"
        id="drive-open"
      >
        {dgettext("settings", "Open in Google Drive")}
      </a>
      <span :if={@pdf.drive_status == "saving"} class="opacity-70" id="drive-saving">
        <span class="loading loading-dots loading-xs align-middle"></span> {dgettext(
          "settings",
          "Saving to Google Drive"
        )}
      </span>
      <a
        :if={@pdf.drive_status == "failed" && @pdf.drive_error == "reconnect"}
        href={~p"/journal/book/drive/connect?#{[pdf: @pdf.id]}"}
        class="link text-warning"
        id="drive-reconnect"
      >
        {dgettext("settings", "Reconnect Google Drive to save it")}
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
          do: dgettext("settings", "Saving to Drive failed. Try again"),
          else: dgettext("settings", "Save to Google Drive")}
      </button>
    </span>
    """
  end

  defp megabytes(nil), do: ""
  defp megabytes(bytes), do: :erlang.float_to_binary(bytes / 1_000_000, decimals: 1) <> " MB"

  defp size_label("a5"), do: "A5"
  defp size_label("a4"), do: "A4"
  defp size_label("letter"), do: dgettext("settings", "Letter")
  defp size_label(other), do: other

  # "(1.2 MB, 12 pages, Letter, composed, made Sep 12)" under the download link
  defp pdf_details(pdf) do
    values = [
      size: megabytes(pdf.byte_size),
      pages: pdf.pages,
      paper: size_label(pdf.page_size),
      date: TravelingPoet.Locale.format_date(pdf.rendered_at, :short)
    ]

    if pdf.variant == "composed",
      do:
        dgettext(
          "settings",
          "(%{size}, %{pages} pages, %{paper}, composed, made %{date})",
          values
        ),
      else: dgettext("settings", "(%{size}, %{pages} pages, %{paper}, made %{date})", values)
  end

  # What a day costs, in the mode the poet is in (the same for both, dec-013)
  defp daily_cost_text(poet) do
    milli = Credits.daily_run_cost(poet)

    dngettext(
      "settings",
      "Each day's journey costs %{amount} credit, wandering or scouting a trip; chatting and drawings are included.",
      "Each day's journey costs %{amount} credits, wandering or scouting a trip; chatting and drawings are included.",
      if(milli == 1000, do: 1, else: 2),
      amount: Credits.format(milli)
    )
  end

  defp signed(milli) when milli >= 0, do: "+" <> Credits.format(milli)
  defp signed(milli), do: "−" <> Credits.format(-milli)

  defp book_status(%{edition: %{status: "composing"}}), do: :composing
  defp book_status(%{edition: %{status: "ready"}}), do: :ready
  defp book_status(%{edition: %{status: "failed"}}), do: :failed
  defp book_status(_book), do: :none

  # "3 credits", "1 credit": a credit count is in milli-credits and may be
  # fractional, so the word follows the amount itself
  defp credit_amount(1000 = milli),
    do: dgettext("settings", "%{amount} credit", amount: Credits.format(milli))

  defp credit_amount(milli),
    do: dgettext("settings", "%{amount} credits", amount: Credits.format(milli))

  defp dollars(cents),
    do: "$#{:erlang.float_to_binary(cents / 100, decimals: 2) |> String.replace(~r/\.00$/, "")}"

  defp reading_items(poet), do: get_in(poet.currently_reading || %{}, ["items"]) || []

  defp save_reading(socket, items) do
    case Poets.update_poet(socket.assigns.poet, %{currently_reading: %{"items" => items}}) do
      {:ok, updated} ->
        assign(socket, :poet, updated)

      {:error, _} ->
        put_flash(socket, :error, dgettext("settings", "Could not save the reading list."))
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
    |> then(&dgettext("settings", "Could not save the topic: %{errors}.", errors: &1))
  end

  defp cadence_options,
    do: [
      {5, dgettext("settings", "every 5 days")},
      {7, dgettext("settings", "every week")},
      {10, dgettext("settings", "every 10 days")},
      {14, dgettext("settings", "every two weeks")}
    ]

  # What to write under each domain, and a short example that fits in the
  # box on a phone.
  defp taste_hint(domain), do: domain |> Topic.hint() |> elem(0)

  defp taste_placeholder(domain),
    do: dgettext("settings", "e.g. %{example}", example: domain |> Topic.hint() |> elem(1))

  defp parse_domain(value) when is_binary(value),
    do: if(value in Topic.domains(), do: value)

  defp parse_domain(_), do: nil

  defp kind_options,
    do: [
      {"", dgettext("settings", "not sure")},
      {"professional", dgettext("settings", "work or study")},
      {"personal", dgettext("settings", "passion")}
    ]

  defp topic_status_label(%Topic{status: "proposed"}),
    do: dgettext("settings", "proposed by your poet")

  defp topic_status_label(%Topic{status: "paused"}), do: dgettext("settings", "paused")
  defp topic_status_label(%Topic{source: "chat"}), do: dgettext("settings", "from chat")
  defp topic_status_label(%Topic{source: "ask"}), do: dgettext("settings", "from your answer")
  defp topic_status_label(_), do: nil

  # "last excursion Sep 12, next in 3 days" for an active topic; nothing for
  # the others (a paused topic has no next, a proposal is not yet followed).
  defp topic_schedule(%Topic{status: "active"} = topic, poet_name) do
    last =
      case Topics.last_excursion_on(topic) do
        nil ->
          dgettext("settings", "no excursion yet")

        date ->
          dgettext("settings", "last excursion %{date}",
            date: TravelingPoet.Locale.format_date(date, :short)
          )
      end

    next =
      case Topics.days_until_due(topic) do
        :due ->
          dgettext("settings", "next on the first day %{poet} stays put", poet: poet_name)

        n ->
          dngettext("settings", "next in a day", "next in %{count} days", n)
      end

    dgettext("settings", "%{last}, %{next}", last: last, next: next)
  end

  defp topic_schedule(_topic, _poet_name), do: nil

  defp verbosity_options do
    [
      {"brief", dgettext("settings", "Brief — short postcards, a few lines and a poem")},
      {"balanced", dgettext("settings", "Balanced — a paragraph or two per section")},
      {"expansive", dgettext("settings", "Expansive — full travel-journal essays")}
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

  attr :topic, :map, required: true
  attr :poet_name, :string, required: true

  # One topic or taste: its words, its rhythm, and what can be done with it.
  defp topic_row(assigns) do
    ~H"""
    <li
      id={"topic-#{@topic.id}"}
      class={[
        "p-2 rounded-lg border border-base-200",
        @topic.status == "paused" && "opacity-60"
      ]}
    >
      <form
        id={"topic-form-#{@topic.id}"}
        phx-change="save_topic"
        phx-value-id={@topic.id}
        class="flex flex-wrap items-center gap-2"
      >
        <input type="hidden" name="topic_id" value={@topic.id} />
        <input
          type="text"
          name="label"
          phx-debounce="750"
          value={@topic.label}
          class="input input-bordered input-sm flex-1 min-w-40"
        />
        <select
          :if={is_nil(@topic.domain)}
          name="kind"
          class="select select-bordered select-sm"
        >
          <option
            :for={{value, label} <- kind_options()}
            value={value}
            selected={(@topic.kind || "") == value}
          >
            {label}
          </option>
        </select>
        <select
          name="every_days"
          class="select select-bordered select-sm"
          disabled={@topic.status == "proposed"}
        >
          <option
            :for={{days, label} <- cadence_options()}
            value={days}
            selected={@topic.every_days == days}
          >
            {label}
          </option>
        </select>
      </form>
      <div class="flex items-center gap-2 mt-1 text-xs opacity-60">
        <span :if={topic_status_label(@topic)}>{topic_status_label(@topic)}</span>
        <span :if={topic_schedule(@topic, @poet_name)}>{topic_schedule(@topic, @poet_name)}</span>
        <span :if={@topic.evidence["quote"]} class="italic">
          &ldquo;{@topic.evidence["quote"]}&rdquo;
        </span>
        <span class="flex-1"></span>
        <button
          :if={@topic.status == "proposed"}
          type="button"
          phx-click="keep_topic"
          phx-value-id={@topic.id}
          class="btn btn-primary btn-xs"
        >
          {dgettext("settings", "Keep")}
        </button>
        <button
          :if={@topic.status == "proposed"}
          type="button"
          phx-click="remove_topic"
          phx-value-id={@topic.id}
          class="btn btn-ghost btn-xs"
        >
          {dgettext("settings", "Not this")}
        </button>
        <button
          :if={@topic.status == "active"}
          type="button"
          phx-click="pause_topic"
          phx-value-id={@topic.id}
          class="btn btn-ghost btn-xs"
        >
          {dgettext("settings", "Pause")}
        </button>
        <button
          :if={@topic.status == "paused"}
          type="button"
          phx-click="resume_topic"
          phx-value-id={@topic.id}
          class="btn btn-ghost btn-xs"
        >
          {dgettext("settings", "Resume")}
        </button>
        <button
          :if={@topic.status != "proposed"}
          type="button"
          phx-click="remove_topic"
          phx-value-id={@topic.id}
          class="btn btn-ghost btn-xs"
          title={dgettext("settings", "Remove")}
        >
          ✕
        </button>
      </div>
    </li>
    """
  end

  @impl true
  def handle_async(:understand_note, _result, socket) do
    {:noreply,
     socket
     |> assign(:understanding, false)
     |> assign_note()
     |> assign_topics()
     |> assign_learned()}
  end

  defp invited_by_name(%{name: name}) when is_binary(name) and name != "",
    do: name |> String.split() |> List.first()

  defp invited_by_name(_), do: dgettext("settings", "a friend")

  # The menu's order is the page's order.
  defp nav_sections(poet) do
    [
      {"poet", poet.name},
      {"about", dgettext("settings", "About you")},
      {"journey", dgettext("settings", "Journey")},
      {"home", dgettext("settings", "Home")},
      {"trips", dgettext("settings", "Trips")},
      {"book", dgettext("settings", "Your book")},
      {"topics", dgettext("settings", "Topics")},
      {"tastes", dgettext("settings", "Tastes")},
      {"learned", dgettext("settings", "Learned")},
      {"credits", dgettext("settings", "Credits")},
      {"invite", dgettext("settings", "Invite friends")},
      {"notifications", dgettext("settings", "Notifications")},
      {"account", dgettext("settings", "Account")}
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
          <h1 class="text-2xl font-semibold">{dgettext("settings", "Settings")}</h1>
          <div class="flex items-center gap-1">
            <.link id="take-the-tour" navigate={~p"/journal?tour=1"} class="btn btn-ghost btn-sm">
              {dgettext("settings", "Take the tour")}
            </.link>
            <.link navigate={~p"/journal"} class="btn btn-ghost btn-sm">
              {dgettext("settings", "← Journal")}
            </.link>
          </div>
        </div>

        <div :if={@poet} class="settings-layout">
          <.settings_nav sections={nav_sections(@poet)} />

          <div class="settings-main">
            <.settings_section
              id="poet"
              title={@poet.name}
              note={dgettext("settings", "Changes save automatically.")}
            >
              <form id="poet-settings-form" phx-change="save_poet" class="space-y-4">
                <label class="block">
                  <span class="text-sm font-medium">{dgettext("settings", "Poet's name")}</span>
                  <input
                    type="text"
                    name="poet_name"
                    phx-debounce="750"
                    value={@poet.name}
                    class="input input-bordered w-full mt-1"
                  />
                  <span class="text-xs opacity-50">
                    {dgettext(
                      "settings",
                      "Shows in the journal right away; the poet's own introduction updates on the next repack, and the journal link keeps its current address."
                    )}
                  </span>
                </label>

                <label class="block">
                  <span class="text-sm font-medium">
                    {dgettext("settings", "%{poet}'s personality", poet: @poet.name)}
                  </span>
                  <textarea
                    name="personality"
                    phx-debounce="750"
                    class="textarea textarea-bordered w-full mt-1"
                  >{@poet.personality}</textarea>
                </label>

                <label class="block">
                  <span class="text-sm font-medium">
                    {dgettext("settings", "What you want %{poet} to look for", poet: @poet.name)}
                  </span>
                  <input
                    type="text"
                    name="interests"
                    phx-debounce="750"
                    value={Enum.join(@poet.interests || [], ", ")}
                    placeholder={dgettext("settings", "street food, bridges, hidden gardens")}
                    class="input input-bordered w-full mt-1"
                  />
                  <span class="text-xs opacity-50">
                    {dgettext("settings", "Comma separated. Takes effect on tomorrow's entry.")}
                  </span>
                </label>

                <label class="block">
                  <span class="text-sm font-medium">
                    {dgettext("settings", "Days to stay in each place")}
                  </span>
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
                    {dgettext("settings", "Staying put through %{date}, as you asked in chat.",
                      date: TravelingPoet.Locale.format_date(@poet.hold_until, :month_day)
                    )}
                  </span>
                  <button type="button" phx-click="release_hold" class="btn btn-ghost btn-xs">
                    {dgettext("settings", "Let it move on")}
                  </button>
                </p>

                <label class="block">
                  <span class="text-sm font-medium">{dgettext("settings", "Journal chattiness")}</span>
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
                    <b>{dgettext("settings", "Public journal")}</b>
                    <span class="block text-sm opacity-60">
                      {dgettext(
                        "settings",
                        "Show %{poet} on the world map; anyone can read the journal",
                        poet: @poet.name
                      )}
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
                  <span>{dgettext("settings", "Telegram note when a new entry is published")}</span>
                </label>
              </form>

              <div class="mt-5">
                <span class="text-sm font-medium">
                  {dgettext("settings", "What %{poet} is reading", poet: @poet.name)}
                </span>
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
                      title={dgettext("settings", "Remove")}
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
                  placeholder={dgettext("settings", "Add another book for the road…")}
                />
                <button type="submit" class="btn btn-sm">{dgettext("settings", "Add")}</button>
              </form>
            </.settings_section>

            <.settings_section id="about" title={dgettext("settings", "About you")}>
              <p class="text-sm opacity-60 mb-3">
                <span :if={is_nil(@note)}>
                  {dgettext(
                    "settings",
                    "A few lines about what you love, what you follow and what you would rather skip. %{poet} writes them after its next page, from what it knows of you. Or write them yourself now.",
                    poet: @poet.name
                  )}
                </span>
                <span :if={@note && @note.written_by == "poet"}>
                  {dgettext(
                    "settings",
                    "%{poet} wrote this from what it knows of you. Change anything: once you save it, these are your words, and %{poet} goes by them.",
                    poet: @poet.name
                  )}
                </span>
                <span :if={@note && @note.written_by == "reader"}>
                  {dgettext(
                    "settings",
                    "In your words. %{poet} goes by this over anything it has guessed.",
                    poet: @poet.name
                  )}
                </span>
              </p>

              <form id="reader-note-form" phx-submit="save_note" class="space-y-2">
                <textarea
                  id="reader-note-text"
                  name="text"
                  rows="5"
                  dir="auto"
                  maxlength={ReaderNote.Note.max_chars()}
                  class="textarea textarea-bordered w-full text-base leading-relaxed"
                  placeholder={
                    dgettext(
                      "settings",
                      "I travel for specialty coffee and modern local food. I follow kit airplanes. I would rather skip nightlife."
                    )
                  }
                >{@note && @note.text}</textarea>
                <div class="flex items-center gap-3">
                  <button type="submit" class="btn btn-sm btn-primary">
                    {dgettext("settings", "Save")}
                  </button>
                  <span :if={@understanding} class="text-xs opacity-60">
                    {dgettext("settings", "Reading it...")}
                  </span>
                </div>
              </form>

              <div
                :if={@note && understood_any?(@note.understood)}
                id="reader-note-understood"
                class="mt-3 text-sm"
              >
                <p class="opacity-60 mb-1">
                  {dgettext("settings", "What %{poet} took from it:", poet: @poet.name)}
                </p>
                <ul class="flex flex-wrap gap-1.5">
                  <li
                    :for={t <- @note.understood["tastes"] || []}
                    class="badge badge-ghost h-auto py-1"
                  >
                    {Topic.domain_label(t["domain"])}: {t["label"]}
                  </li>
                  <li
                    :for={t <- @note.understood["topics"] || []}
                    class="badge badge-ghost h-auto py-1"
                  >
                    {dgettext("settings", "Follows: %{label}", label: t["label"])}
                  </li>
                  <li
                    :for={a <- @note.understood["avoids"] || []}
                    class="badge badge-ghost h-auto py-1"
                  >
                    {dgettext("settings", "Skips: %{label}", label: a["label"])}
                  </li>
                </ul>
                <p class="text-xs opacity-50 mt-1">
                  {dgettext(
                    "settings",
                    "Added to your topics, tastes and what %{poet} has learned, below. Taking a line out of the note does not remove them; remove them there.",
                    poet: @poet.name
                  )}
                </p>
              </div>

              <ul :if={@note_suggestions != []} id="reader-note-suggestions" class="mt-4 space-y-2">
                <li
                  :for={s <- @note_suggestions}
                  id={"note-line-#{s.id}"}
                  class="p-3 rounded-lg bg-base-200 text-sm"
                >
                  <p class="opacity-60">
                    {if s.kind == "add",
                      do: dgettext("settings", "%{poet} suggests adding:", poet: @poet.name),
                      else: dgettext("settings", "%{poet} suggests taking out:", poet: @poet.name)}
                  </p>
                  <p class={["my-1", s.kind == "strike" && "line-through"]} dir="auto">{s.text}</p>
                  <p :if={s.reason} class="text-xs opacity-60" dir="auto">{s.reason}</p>
                  <div class="flex gap-2 mt-2">
                    <button
                      phx-click="accept_note_line"
                      phx-value-id={s.id}
                      class="btn btn-xs btn-primary"
                    >
                      {if s.kind == "add",
                        do: dgettext("settings", "Add it"),
                        else: dgettext("settings", "Take it out")}
                    </button>
                    <button
                      phx-click="decline_note_line"
                      phx-value-id={s.id}
                      class="btn btn-xs btn-ghost"
                    >
                      {dgettext("settings", "No thanks")}
                    </button>
                  </div>
                </li>
              </ul>
            </.settings_section>

            <.settings_section id="journey" title={dgettext("settings", "Journey")}>
              <div class="flex gap-2 mb-3">
                <button
                  phx-click="switch_mode"
                  phx-value-mode="wander"
                  class={["btn btn-sm flex-1", Poet.mode(@poet) == "wander" && "btn-primary"]}
                >
                  🧭 {dgettext("settings", "Wanderer")}
                </button>
                <button
                  phx-click="switch_mode"
                  phx-value-mode="scout"
                  class={["btn btn-sm flex-1", Poet.mode(@poet) == "scout" && "btn-primary"]}
                >
                  🗺️ {dgettext("settings", "Trip Scout")}
                </button>
              </div>
              <p class="text-xs opacity-60 mb-4">
                {dgettext(
                  "settings",
                  "Switching missions repacks your poet (~2 minutes). Trip Scouts follow the itinerary below, in order."
                )}
              </p>

              <h3 class="text-sm font-medium mb-2">
                {if Poet.mode(@poet) != "scout",
                  do: dgettext("settings", "Trip itinerary (used in Trip Scout mode)"),
                  else: dgettext("settings", "Trip itinerary")}
              </h3>
              <form phx-submit="search_stop" class="flex gap-2 mb-2">
                <input
                  type="text"
                  name="query"
                  value={@stop_query}
                  class="input input-bordered input-sm flex-1"
                  placeholder={dgettext("settings", "Add a place…")}
                />
                <button type="submit" class="btn btn-sm">{dgettext("settings", "Search")}</button>
              </form>
              <p :if={@stop_error} class="text-error text-xs mb-2">{@stop_error}</p>
              <div :if={@stop_results != []} class="space-y-1 mb-2">
                <button
                  :for={{result, idx} <- Enum.with_index(@stop_results)}
                  phx-click="add_stop"
                  phx-value-idx={idx}
                  class="btn btn-outline btn-xs w-full justify-start text-start normal-case"
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
                    <span :if={stop.source == "chat"} class="badge badge-ghost badge-xs ms-1">
                      {dgettext("settings", "asked in chat")}
                    </span>
                    <span :if={stop.source == "trip"} class="badge badge-ghost badge-xs ms-1">
                      {dgettext("settings", "for your trip")}
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
              <p :if={@stops == []} class="text-xs opacity-60 mb-2">
                {dgettext("settings", "No stops yet.")}
              </p>
            </.settings_section>

            <.settings_section
              id="home"
              title={dgettext("settings", "Home")}
              note={
                dgettext(
                  "settings",
                  "Where you live: trips are measured from here, and Near you looks around it."
                )
              }
            >
              <.home_settings trips={@trips} user={@user} poet={@poet} />
            </.settings_section>

            <.settings_section
              :if={@trips.enabled?}
              id="trips"
              title={dgettext("settings", "Trips")}
              note={dgettext("settings", "Trips on your calendar, scouted before you go.")}
            >
              <.trip_settings trips={@trips} user={@user} poet={@poet} />
            </.settings_section>

            <.settings_section id="book" title={dgettext("settings", "Your book")}>
              <p class="text-sm opacity-70 mb-3">
                {dgettext(
                  "settings",
                  "The whole journal as one printable notebook: a chapter for every place, a table of contents, every drawing with what it was drawn from, every source written out. Print it or save it as a PDF from your browser. Free."
                )}
              </p>
              <a
                href={~p"/journal/book"}
                target="_blank"
                class="btn btn-outline btn-sm"
                id="open-book"
              >
                <.icon name="hero-book-open" class="size-4" /> {dgettext("settings", "Open the book")}
              </a>

              <div :if={@book && @book.pdf_enabled && @book.chapters > 0} class="mt-4" id="book-pdf">
                <h3 class="text-sm font-medium mb-1">{dgettext("settings", "A PDF to keep")}</h3>
                <p class="text-sm opacity-70 mb-2">
                  {dgettext(
                    "settings",
                    "The book as a PDF file, made on %{poet}'s own machine, ready to download, print or share. Free.",
                    poet: @poet.name
                  )}
                </p>

                <div :if={@book.last_ready_pdf} class="text-sm mb-2" id="book-pdf-ready">
                  <a
                    href={~p"/journal/book/pdf/#{@book.last_ready_pdf.id}"}
                    class="link font-medium"
                    id="book-pdf-download"
                  >
                    <.icon name="hero-arrow-down-tray" class="size-4" /> {dgettext(
                      "settings",
                      "Download the PDF"
                    )}
                  </a>
                  <.drive_save pdf={@book.last_ready_pdf} connected={@book.drive_connected} />
                  <span class="opacity-60 block">
                    {pdf_details(@book.last_ready_pdf)}
                  </span>
                </div>

                <p
                  :if={match?(%{status: "rendering"}, @book.pdf)}
                  class="text-sm mb-2"
                  id="book-pdf-rendering"
                >
                  <span class="loading loading-dots loading-xs align-middle"></span>
                  {dgettext(
                    "settings",
                    "Making your PDF. The first one takes a couple of minutes longer while %{poet}'s machine gets ready.",
                    poet: @poet.name
                  )}
                </p>

                <p
                  :if={match?(%{status: "failed"}, @book.pdf)}
                  class="text-sm text-warning mb-2"
                  id="book-pdf-failed"
                >
                  {dgettext("settings", "The last PDF did not come out. You can try again.")}
                </p>

                <form
                  :if={!match?(%{status: "rendering"}, @book.pdf)}
                  phx-submit="make_pdf"
                  id="make-pdf-form"
                  class="flex flex-wrap items-end gap-2"
                >
                  <label class="text-xs">
                    <span class="block opacity-70 mb-1">{dgettext("settings", "Paper")}</span>
                    <select name="page_size" class="select select-sm">
                      <option value="a5">A5</option>
                      <option value="a4">A4</option>
                      <option value="letter">{size_label("letter")}</option>
                    </select>
                  </label>
                  <label :if={@book.has_composed} class="text-xs">
                    <span class="block opacity-70 mb-1">{dgettext("settings", "Edition")}</span>
                    <select name="variant" class="select select-sm">
                      <option value="composed">{dgettext("settings", "Composed")}</option>
                      <option value="plain">{dgettext("settings", "As written")}</option>
                    </select>
                  </label>
                  <button
                    type="submit"
                    class="btn btn-sm btn-outline"
                    disabled={@book.pdf_blocker not in [nil, :poet_busy]}
                    id="make-pdf-button"
                  >
                    {if @book.last_ready_pdf,
                      do: dgettext("settings", "Make a new PDF"),
                      else: dgettext("settings", "Make the PDF")}
                  </button>
                </form>
                <p :if={@book.pdf_blocker == :daily_cap} class="text-xs opacity-70 mt-1">
                  {dgettext("settings", "That is enough PDFs for today. Try again tomorrow.")}
                </p>
                <button
                  :if={@book.drive_connected}
                  type="button"
                  phx-click="disconnect_drive"
                  class="link text-xs opacity-60 mt-2 block"
                  id="disconnect-drive"
                >
                  {dgettext("settings", "Disconnect Google Drive")}
                </button>
                <p :if={@book.pdf_blocker == :no_sprite} class="text-xs opacity-70 mt-1">
                  {@poet.name} is still setting out.
                </p>
              </div>

              <div :if={@book && @book.chapters > 0} class="mt-4" id="compose-book">
                <h3 class="text-sm font-medium mb-1">{dgettext("settings", "A composed edition")}</h3>
                <p class="text-sm opacity-70 mb-2">
                  {dgettext(
                    "settings",
                    "%{poet} writes the words around the journal: a dedication to you, a foreword, an opening for each place, an epilogue, and a few of its own lines set on pages of their own. The journal itself is not changed.",
                    poet: @poet.name
                  )}
                </p>

                <p :if={book_status(@book) == :composing} class="text-sm" id="book-composing">
                  <span class="loading loading-dots loading-xs align-middle"></span>
                  {dgettext(
                    "settings",
                    "%{poet} is composing your book. It takes a few minutes; this page updates when it is done.",
                    poet: @poet.name
                  )}
                </p>

                <p :if={book_status(@book) == :ready} class="text-sm mb-2" id="book-ready">
                  {dgettext("settings", "Composed on %{date}. It is in the book now.",
                    date: TravelingPoet.Locale.format_date(@book.edition.composed_at, :month_day)
                  )}
                </p>

                <p
                  :if={book_status(@book) == :failed}
                  class="text-sm text-warning mb-2"
                  id="book-failed"
                >
                  {dgettext(
                    "settings",
                    "The last composition did not finish, so nothing was charged for it."
                  )}
                </p>

                <button
                  :if={book_status(@book) != :composing}
                  phx-click="compose_book"
                  class="btn btn-sm btn-primary"
                  disabled={@book.blocker not in [nil, :poet_busy]}
                  id="compose-book-button"
                >
                  {if book_status(@book) == :ready,
                    do: dgettext("settings", "Compose it again"),
                    else: dgettext("settings", "Ask %{poet} to compose it", poet: @poet.name)}
                  <span class="opacity-80">
                    ({if @book.exempt,
                      do: dgettext("settings", "free"),
                      else: credit_amount(@book.cost)})
                  </span>
                </button>
                <p
                  :if={@book.blocker == :insufficient_credits}
                  class="text-xs text-warning mt-1"
                >
                  {dgettext("settings", "Not enough credits for a composed edition.")}
                </p>
                <p :if={@book.blocker == :daily_cap} class="text-xs opacity-70 mt-1">
                  {dgettext("settings", "That is enough books for today. Try again tomorrow.")}
                </p>
                <p :if={@book.blocker == :no_sprite} class="text-xs opacity-70 mt-1">
                  {@poet.name} is still setting out.
                </p>
              </div>
            </.settings_section>

            <.settings_section
              id="topics"
              title={dgettext("settings", "Topics %{poet} follows for you", poet: @poet.name)}
            >
              <p class="text-sm opacity-60 mb-3">
                {dgettext(
                  "settings",
                  "Beyond places: a field you work in, a passion you keep. Every so often %{poet} takes a day off the road for an excursion into one of these, a conference, a festival, a lab, a company, and writes back about it. Tell %{poet} in chat, or add one here.",
                  poet: @poet.name
                )}
              </p>

              <p :if={@topics == []} class="text-sm opacity-50 mb-2">
                {dgettext("settings", "None yet.")}
              </p>

              <ul class="space-y-2">
                <.topic_row :for={topic <- @topics} topic={topic} poet_name={@poet.name} />
              </ul>

              <div :if={@queued_excursions != []} class="mt-3">
                <h3 class="text-sm font-medium mb-1">{dgettext("settings", "Asked for in chat")}</h3>
                <ul id="queued-excursions" class="space-y-1">
                  <li
                    :for={x <- @queued_excursions}
                    id={"excursion-#{x.id}"}
                    class="flex items-center gap-2 text-sm p-2 rounded-lg bg-base-200"
                  >
                    <span class="flex-1">
                      {x.requested_destination}
                      <span class="opacity-60">
                        {dgettext("settings", "for %{topic}", topic: x.topic.label)}
                      </span>
                    </span>
                    <span class="text-xs opacity-60">
                      {dgettext("settings", "on the next day %{poet} stays put", poet: @poet.name)}
                    </span>
                    <button
                      type="button"
                      phx-click="remove_excursion"
                      phx-value-id={x.id}
                      class="btn btn-ghost btn-xs"
                      title={dgettext("settings", "Remove")}
                    >
                      ✕
                    </button>
                  </li>
                </ul>
              </div>

              <form id="add-topic-form" phx-submit="add_topic" class="mt-3 space-y-2">
                <input
                  type="text"
                  name="label"
                  class="input input-bordered input-sm w-full"
                  placeholder={
                    dgettext("settings", "Add a topic, like kit airplanes or embodied minds")
                  }
                />
                <div class="flex gap-2">
                  <select name="kind" class="select select-bordered select-sm flex-1">
                    <option :for={{value, label} <- kind_options()} value={value}>{label}</option>
                  </select>
                  <button type="submit" class="btn btn-sm">{dgettext("settings", "Add")}</button>
                </div>
              </form>
            </.settings_section>

            <.settings_section
              id="tastes"
              title={dgettext("settings", "Tastes %{poet} looks for", poet: @poet.name)}
            >
              <p class="text-sm opacity-60 mb-3">
                {dgettext(
                  "settings",
                  "Tell %{poet} what you love in each of these, in your own words. On a taste's day, %{poet} goes looking for new things that fit it and brings back a few, each with why it chose them.",
                  poet: @poet.name
                )}
              </p>

              <div class="space-y-4">
                <div :for={domain <- Topic.domains()} id={"tastes-#{domain}"}>
                  <h3 class="text-sm font-medium">{Topic.domain_label(domain)}</h3>
                  <p class="text-xs opacity-60 mb-1">{taste_hint(domain)}</p>
                  <ul :if={@tastes[domain]} class="space-y-2 mb-2">
                    <.topic_row
                      :for={topic <- @tastes[domain]}
                      topic={topic}
                      poet_name={@poet.name}
                    />
                  </ul>
                  <form id={"add-taste-#{domain}"} phx-submit="add_topic" class="flex gap-2">
                    <input type="hidden" name="domain" value={domain} />
                    <input
                      type="text"
                      name="label"
                      class="input input-bordered input-sm flex-1 min-w-0"
                      placeholder={taste_placeholder(domain)}
                    />
                    <button type="submit" class="btn btn-sm">{dgettext("settings", "Add")}</button>
                  </form>
                </div>
              </div>
            </.settings_section>

            <.settings_section
              id="learned"
              title={dgettext("settings", "What %{poet} has learned about you", poet: @poet.name)}
            >
              <p class="text-sm opacity-60 mb-3">
                {dgettext(
                  "settings",
                  "Picked up from what you tap under an entry and what you say in chat. %{poet} applies these on its own — remove anything that isn't right.",
                  poet: @poet.name
                )}
              </p>

              <p :if={@learned == []} class="text-sm opacity-50">
                {dgettext(
                  "settings",
                  "Nothing yet. Answer a question under an entry, or just tell %{poet} in chat what you'd rather read about.",
                  poet: @poet.name
                )}
              </p>

              <ul class="space-y-2">
                <li
                  :for={pref <- @learned}
                  class="flex items-start gap-2 p-2 rounded-lg border border-base-200"
                >
                  <div class="flex-1">
                    <div class="text-sm">
                      <span :if={pref.polarity == "avoid"} class="opacity-60">{dgettext("settings", "less:")} </span>{pref.label}
                    </div>
                    <div class="text-xs opacity-50">
                      {source_label(pref.source)}
                      <span :if={pref.weight > 1}>
                        · {dgettext("settings", "mentioned %{n}×", n: pref.weight)}
                      </span>
                      <span :if={pref.evidence["quote"]} class="italic">
                        · &ldquo;{pref.evidence["quote"]}&rdquo;
                      </span>
                    </div>
                  </div>
                  <button
                    phx-click="dismiss_preference"
                    phx-value-id={pref.id}
                    class="btn btn-ghost btn-xs"
                    title={dgettext("settings", "Remove")}
                  >
                    ✕
                  </button>
                </li>
              </ul>

              <div id="lingering" class="mt-5 border-t border-base-200 pt-4">
                <h3 class="font-medium mb-1">{dgettext("settings", "Subjects you linger on")}</h3>
                <p class="text-sm opacity-60 mb-3">
                  {dgettext(
                    "settings",
                    "From the topics and tastes you keep, the passages you mark, the entries you react to and the paragraphs you read through. Recent signals count most."
                  )}
                </p>
                <p :if={@affinity == []} class="text-sm opacity-50">
                  {dgettext(
                    "settings",
                    "Nothing yet. Read your journal, mark what catches you, and this fills in."
                  )}
                </p>
                <.taste_map :if={@affinity != []} profile={@affinity} />
                <ul :if={@affinity_top != []} class="mt-3 space-y-1" id="lingering-list">
                  <li :for={s <- @affinity_top} class="flex items-center gap-2 text-sm">
                    <span class="flex-1">
                      {Enum.at(s.names, 2)} <span class="opacity-50">· {hd(s.names)}</span>
                    </span>
                    <button
                      phx-click="dismiss_subject"
                      phx-value-path={s.path}
                      class="btn btn-ghost btn-xs"
                      title={dgettext("settings", "Not really me")}
                    >
                      ✕
                    </button>
                  </li>
                </ul>
                <details :if={@affinity_dismissed != []} class="mt-2" id="lingering-removed">
                  <summary class="text-xs opacity-50 cursor-pointer">
                    {dgettext("settings", "Removed (%{n})", n: length(@affinity_dismissed))}
                  </summary>
                  <ul class="mt-2 space-y-1">
                    <li
                      :for={s <- @affinity_dismissed}
                      class="flex items-center gap-2 text-sm opacity-60"
                    >
                      <span class="flex-1">{Enum.at(s.names, 2)}</span>
                      <button
                        phx-click="restore_subject"
                        phx-value-path={s.path}
                        class="btn btn-ghost btn-xs"
                      >
                        {dgettext("settings", "restore")}
                      </button>
                    </li>
                  </ul>
                </details>
              </div>

              <form id="reading-signals-form" phx-change="toggle_reading" class="mt-4">
                <input type="hidden" name="reading_signals" value="false" />
                <label class="flex items-center gap-3">
                  <input
                    type="checkbox"
                    name="reading_signals"
                    value="true"
                    class="toggle"
                    checked={@user.reading_signals}
                  />
                  <span>
                    <b>{dgettext("settings", "Learn from how I read")}</b>
                    <span class="block text-sm opacity-60">
                      {dgettext(
                        "settings",
                        "Notes how long you spend on each paragraph of your own journal, so %{poet} learns which subjects you linger on. Only on your journal, only for you. Turning it off forgets what was noted.",
                        poet: @poet.name
                      )}
                    </span>
                  </span>
                </label>
              </form>

              <details :if={@dismissed != []} class="mt-3">
                <summary class="text-xs opacity-50 cursor-pointer">
                  {dgettext("settings", "Removed (%{n})", n: length(@dismissed))}
                </summary>
                <ul class="mt-2 space-y-1">
                  <li :for={pref <- @dismissed} class="flex items-center gap-2 text-sm opacity-60">
                    <span class="flex-1">{pref.label}</span>
                    <button
                      phx-click="restore_preference"
                      phx-value-id={pref.id}
                      class="btn btn-ghost btn-xs"
                    >
                      {dgettext("settings", "restore")}
                    </button>
                  </li>
                </ul>
              </details>
            </.settings_section>

            <.settings_section id="credits" title={dgettext("settings", "Credits")}>
              <div class="flex items-baseline gap-3">
                <span class="text-3xl font-semibold" id="credits-balance">
                  {Credits.format(@balance)}
                </span>
                <span class="text-sm opacity-60">{dgettext("settings", "credits")}</span>
              </div>
              <p class={["text-sm mt-1", @credits_low && "text-warning"]}>{runway_text(@runway)}</p>
              <p :if={@credits_exhausted} class="text-sm text-error mt-1">
                {dgettext("settings", "Your poet is resting until you top up.")}
              </p>
              <p class="text-xs opacity-60 mt-2 mb-3">
                {daily_cost_text(@poet)}
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
                    <span class="font-semibold">
                      {dgettext("settings", "%{n} credits", n: pack.credits)}
                    </span>
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
                {dgettext("settings", "Payments are in test mode — purchases are mocked and free.")}
              </p>

              <details :if={@transactions != []} class="text-sm">
                <summary class="cursor-pointer opacity-70">
                  {dgettext("settings", "Recent activity")}
                </summary>
                <ul class="mt-2 space-y-1">
                  <li :for={tx <- @transactions} class="flex justify-between gap-2">
                    <span>{tx_label(tx.kind)}</span>
                    <span class="opacity-60 text-xs">
                      {TravelingPoet.Locale.format_date(tx.inserted_at, :short)}
                    </span>
                    <span class={["tabular-nums", tx.amount < 0 && "opacity-70"]}>
                      {signed(tx.amount)}
                    </span>
                  </li>
                </ul>
              </details>
            </.settings_section>

            <.settings_section id="invite" title={dgettext("settings", "Invite friends")}>
              <p class="text-sm mb-3">
                {dgettext(
                  "settings",
                  "Give a friend a poet of their own. They start with %{credits} extra credits, and you get %{credits} when their poet's first page arrives.",
                  credits: Referrals.referral_credits()
                )}
              </p>
              <p class="text-sm mb-2">
                <span class="opacity-60">{dgettext("settings", "Your invite link:")}</span>
                <span id="invite-url" class="font-mono break-all">{@invite_url}</span>
              </p>
              <.invite_actions
                id="settings-invite"
                url={@invite_url}
                title="Traveling Poet"
                text={invite_text(@poet.name)}
              />
              <p :if={@invite_stats.joined > 0} id="invite-stats" class="text-sm opacity-70 mt-3">
                {dngettext(
                  "settings",
                  "One friend joined through you",
                  "%{count} friends joined through you",
                  @invite_stats.joined
                )}
                <span :if={@invite_stats.earned > 0}>
                  {dgettext("settings", "(%{credits} credits earned so far).",
                    credits: Credits.format(@invite_stats.earned)
                  )}
                </span>
              </p>
              <p :if={@invited_by} id="invited-by" class="text-xs opacity-60 mt-3">
                {dgettext("settings", "You joined through %{friend}'s invite.",
                  friend: invited_by_name(@invited_by)
                )}
              </p>
              <form
                :if={@can_claim_invite}
                id="invite-claim-form"
                phx-submit="claim_invite"
                class="mt-4 flex flex-wrap items-end gap-2"
              >
                <label class="text-sm">
                  <span class="block opacity-70 mb-1">
                    {dgettext("settings", "Got an invite code from a friend?")}
                  </span>
                  <input
                    type="text"
                    name="code"
                    autocomplete="off"
                    autocapitalize="characters"
                    maxlength="16"
                    class="input input-sm input-bordered w-40 font-mono uppercase"
                  />
                </label>
                <button type="submit" class="btn btn-sm">{dgettext("settings", "Use code")}</button>
              </form>
            </.settings_section>

            <.settings_section id="notifications" title={dgettext("settings", "Notifications")}>
              <form id="email-notify-form" phx-change="toggle_email" class="mb-4">
                <input type="hidden" name="email_notify" value="false" />
                <label class="flex items-center gap-3">
                  <input
                    type="checkbox"
                    name="email_notify"
                    value="true"
                    class="toggle"
                    checked={@user.email_notify}
                  />
                  <span>
                    <b>{dgettext("settings", "Email me each new page")}</b>
                    <span class="block text-sm opacity-60">
                      {dgettext(
                        "settings",
                        "One email a day, only when %{poet} publishes a new page, with its drawing. To %{email}.",
                        poet: @poet.name,
                        email: @user.email
                      )}
                    </span>
                  </span>
                </label>
                <input type="hidden" name="email_full_page" value="false" />
                <label class={["flex items-center gap-3 mt-3", !@user.email_notify && "opacity-50"]}>
                  <input
                    type="checkbox"
                    name="email_full_page"
                    value="true"
                    class="toggle toggle-sm"
                    checked={@user.email_full_page}
                    disabled={!@user.email_notify}
                  />
                  <span>
                    <b>{dgettext("settings", "Send the whole page")}</b>
                    <span class="block text-sm opacity-60">
                      {dgettext(
                        "settings",
                        "The page's words, drawings and places in the email itself, to read without opening the app. Replies and markers stay on the page."
                      )}
                    </span>
                  </span>
                </label>
              </form>
              <div class="settings-rule"></div>
              <.push_settings push={@push} poet={@poet} />
              <div class="settings-rule"></div>
              <.telegram_settings telegram={@telegram} user={@user} poet={@poet} />
            </.settings_section>

            <.settings_section id="account" title={dgettext("settings", "Account")}>
              <form id="user-settings-form" phx-change="save_user" class="mb-4">
                <label class="block">
                  <span class="text-sm font-medium">{dgettext("settings", "Your name")}</span>
                  <input
                    type="text"
                    name="name"
                    phx-debounce="750"
                    value={@user.name}
                    class="input input-bordered w-full mt-1"
                  />
                  <span class="text-xs opacity-50">
                    {dgettext("settings", "How %{poet} addresses you.", poet: @poet.name)}
                  </span>
                </label>
              </form>

              <form id="locale-form" phx-change="set_locale" class="mb-4">
                <label class="block">
                  <span class="text-sm font-medium">{dgettext("settings", "Language")}</span>
                  <select name="locale" class="select select-bordered w-full mt-1">
                    <option
                      :for={locale <- TravelingPoet.Locale.supported()}
                      value={locale}
                      lang={locale}
                      selected={@user.locale == locale}
                    >
                      {TravelingPoet.Locale.native_name(locale)}
                    </option>
                  </select>
                  <span class="text-xs opacity-50">
                    {dgettext(
                      "settings",
                      "The app's language, and the one %{poet} writes in from its next page.",
                      poet: @poet.name
                    )}
                  </span>
                </label>
              </form>

              <a href={~p"/auth/logout"} class="btn btn-ghost btn-sm mt-4">
                {dgettext("settings", "Sign out")}
              </a>

              <p class="text-xs opacity-60 mt-4">
                <.link navigate={~p"/privacy"} class="link">
                  {dgettext("settings", "Privacy policy")}
                </.link>
                ·
                <.link navigate={~p"/terms"} class="link">
                  {dgettext("settings", "Terms of service")}
                </.link>
                ·
                <.link navigate={~p"/support"} class="link">{dgettext("settings", "Support")}</.link>
                ·
                <.link navigate={~p"/feedback?from=/settings"} class="link" id="settings-feedback">
                  {dgettext("settings", "Send feedback")}
                </.link>
              </p>

              <details id="delete-account" class="mt-6 border-t border-base-300 pt-4">
                <summary class="cursor-pointer text-sm text-error">
                  {dgettext("settings", "Delete account")}
                </summary>
                <div class="mt-3 text-sm space-y-3">
                  <p>
                    {dgettext(
                      "settings",
                      "This deletes your account and everything in it, now and for good: %{poet}, every journal entry and drawing, the trip guide, your chat, your credits, and the connections to Google, Apple and Telegram. A public journal stops being readable. Nothing can be restored afterwards, and unused credits are not refunded.",
                      poet: if(@poet, do: @poet.name, else: dgettext("settings", "your poet"))
                    )}
                  </p>
                  <form id="delete-account-form" phx-submit="delete_account" class="space-y-2">
                    <label class="block">
                      <span class="text-sm">
                        <.rich text={
                          dgettext(
                            "settings",
                            "To confirm, type the email address of this account, %{email}",
                            email: marker(:email)
                          )
                        }>
                          <:part name="email"><b>{@user.email}</b></:part>
                        </.rich>
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
                      phx-disable-with={dgettext("settings", "Deleting...")}
                    >
                      {dgettext("settings", "Delete my account for good")}
                    </button>
                  </form>
                </div>
              </details>
            </.settings_section>
          </div>
        </div>

        <div :if={is_nil(@poet)} class="max-w-xl">
          <p class="opacity-70">
            <.rich text={dgettext("settings", "No poet yet — %{link}.", link: marker(:link))}>
              <:part name="link">
                <.link navigate={~p"/onboarding"} class="link">
                  {dgettext("settings", "set one up")}
                </.link>
              </:part>
            </.rich>
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
