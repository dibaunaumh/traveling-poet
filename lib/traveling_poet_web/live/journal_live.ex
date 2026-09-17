defmodule TravelingPoetWeb.JournalLive do
  use TravelingPoetWeb, :live_view

  import TravelingPoetWeb.NotebookComponents
  import TravelingPoetWeb.RouteComponents
  import TravelingPoetWeb.MarkerComponents, only: [marker_menu: 1, icons_json: 0]

  import TravelingPoetWeb.PushNotifications, only: [assign_push: 1, push_nudge: 1, push_tip: 1]
  import TravelingPoetWeb.TelegramPairing, only: [assign_telegram: 1, telegram_tip: 1]

  alias TravelingPoet.{
    Accounts,
    Chat,
    Credits,
    FirstEntry,
    GatewaySocket,
    GatewaySocketSupervisor,
    Journal,
    Markers,
    Poets
  }

  alias TravelingPoet.Journal.Marker
  alias TravelingPoet.Poets.Showcase
  alias TravelingPoet.{Preferences, SpriteHold, SpriteUploads, SpritesClient, Usage}
  alias TravelingPoet.{Guide, Topics}
  alias TravelingPoet.Journal.{EntryBundle, Spreads}
  alias TravelingPoetWeb.ChatSidebarComponent

  require Logger

  # While the reader is active the sprite is held awake with a Sprites task:
  # a 5 min expiry refreshed every minute (the docs' heartbeat pattern), and
  # deleted once the reader has been quiet for the active window.
  @keepalive_interval_ms 60_000
  @keepalive_task_expire "5m"
  @keepalive_active_window_ms 5 * 60 * 1000
  @wake_timeout_ms 30_000
  @wake_poll_ms 2_000
  @chat_attachment_max_bytes 25_000_000
  @setup_refresh_ms 10_000

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    cond do
      not user.onboarding_completed ->
        {:ok, push_navigate(socket, to: ~p"/onboarding")}

      is_nil(Poets.get_poet_by_user(user.id)) ->
        {:ok, push_navigate(socket, to: ~p"/onboarding")}

      true ->
        poet = Poets.get_poet_by_user(user.id)

        gateway_socket_pid =
          if connected?(socket) do
            Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "user:#{user.id}")
            Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "poet:#{poet.id}")
            # The fleet tour shown while waiting follows every poet's publishes.
            Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "journal:published")

            if user.sprite_provisioned do
              Process.send_after(self(), :keepalive, @keepalive_interval_ms)
            end

            # Belt-and-braces for the setting-up screen: PubSub updates the
            # checklist live, but a dropped websocket (backgrounded tab,
            # proxy blip) silently loses broadcasts — beta users refreshed
            # manually to see progress. Poll the DB while setting up.
            Process.send_after(self(), :setup_refresh, @setup_refresh_ms)

            if user.sprite_provisioned && user.sprite_url && user.gateway_token &&
                 user.device_public_key do
              connect_gateway_socket(user)
            end
          end

        initial_sprite_status =
          cond do
            user.sprite_provisioned && user.sprite_url -> :running
            user.sprite_provisioned -> :provisioned
            true -> :not_provisioned
          end

        socket =
          socket
          |> assign(:page_title, "#{poet.name}'s Journal")
          |> assign(:user, user)
          |> assign(:poet, poet)
          |> assign_push()
          |> assign(:sidebar_open, true)
          |> assign(:keepalive_task, SpriteHold.task_name("chat"))
          |> assign(:hold_live, false)
          |> assign(:last_activity_at, nil)
          |> assign(:sprite_status, initial_sprite_status)
          |> assign(:provision_step, nil)
          |> assign(:first_entry, FirstEntry.status(user, poet))
          |> assign(:held_message, nil)
          |> assign(:last_sent, nil)
          |> assign_telegram()
          |> assign(:mobile_chat_open, false)
          |> assign(:gateway_socket_pid, gateway_socket_pid)
          |> assign(:active_marker, nil)
          |> assign_journal(poet, nil)
          |> assign_showcase()
          |> allow_upload(:chat_attachment,
            accept: :any,
            max_entries: 1,
            max_file_size: @chat_attachment_max_bytes,
            auto_upload: true
          )

        {:ok, socket}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns[:poet] do
      nil ->
        {:noreply, socket}

      poet ->
        date =
          with %{"date" => date_str} <- params,
               {:ok, date} <- Date.from_iso8601(date_str) do
            date
          else
            _ -> nil
          end

        # Turning to another spread of the same entry is a patch on the same
        # date: reloading would re-query everything and re-record the view.
        socket =
          if same_entry?(socket, date),
            do: socket,
            else: assign_journal(socket, poet, date)

        {:noreply, socket |> assign_spread(params["spread"]) |> push_map()}
    end
  end

  defp same_entry?(%{assigns: %{entry: %{entry_date: shown}}}, %Date{} = date), do: shown == date
  defp same_entry?(_socket, _date), do: false

  # Keeps the reader's current spread across reloads (a revision, a publish)
  # when it still exists; otherwise the first.
  defp assign_spread(socket, requested) do
    requested = requested || (socket.assigns[:spread] && socket.assigns.spread.key)
    assign(socket, :spread, Spreads.pick(socket.assigns.spreads, requested))
  end

  defp spread_path(entry, key),
    do: ~p"/journal/#{Date.to_iso8601(entry.entry_date)}?spread=#{key}"

  # The map div is phx-update="ignore" (Leaflet owns its DOM), so a changed
  # data-points attribute does NOT re-render it. Paging between entries has to
  # tell the hook directly or the map silently keeps the previous day's view.
  defp push_map(socket) do
    if connected?(socket) and socket.assigns.entries != [] do
      push_event(
        socket,
        "map:update",
        map_points(
          socket.assigns.path_points,
          socket.assigns.poet,
          socket.assigns.entry,
          map_places(socket)
        )
      )
    else
      socket
    end
  end

  defp assign_journal(socket, poet, date) do
    entries = Journal.list_entries(poet.id, status: "published")

    entry =
      cond do
        date -> Journal.get_entry_preloaded(poet.id, date)
        entries != [] -> Journal.preload_entry(hd(entries))
        true -> nil
      end

    entry = record_view(socket, poet, entry)
    bundle = EntryBundle.load(entry)
    entry = bundle.entry

    socket
    |> assign(:entries, entries)
    |> assign(:entry, entry)
    |> assign(:journey_start, Journal.first_published_date(poet.id))
    |> assign(:entry_media, bundle.media)
    |> assign(:extra_media, bundle.extra_media)
    |> assign(:places, bundle.places)
    |> assign(:place_media, bundle.place_media)
    |> assign(:find_media, bundle.find_media)
    |> assign(:spot_media, bundle.spot_media)
    |> assign_stay(poet, bundle.stay_id)
    |> assign_route(poet, entry)
    |> assign(:spreads, bundle.spreads)
    |> assign(:my_reactions, my_reactions(entry, socket.assigns.current_user))
    |> assign(:path_points, Poets.list_path_points(poet.id))
    |> assign_markers(entry)
    |> assign_prompt(poet, entry)
    |> assign_spread(nil)
  end

  # The fleet, for the journey tour that stands in for the map until the
  # first entry lands. Nothing to build once there is a journal to read.
  defp assign_showcase(socket) do
    if socket.assigns.entries == [] do
      assign(socket, :showcase, Showcase.build(socket.assigns.poet))
    else
      assign(socket, :showcase, nil)
    end
  end

  # Feedback markers on the entry, and their JSON for the Markers hook. Runs on
  # every reload path so a revision or a date change never shows stale marks.
  defp assign_markers(socket, nil) do
    socket |> assign(:markers, []) |> assign(:markers_json, "[]")
  end

  defp assign_markers(socket, entry) do
    markers = Markers.list_markers(entry.id)

    socket
    |> assign(:markers, markers)
    |> assign(:markers_json, Jason.encode!(Markers.payload(markers)))
  end

  # Only the owner, and only on the live mount — the dead render would double
  # count every page load.
  defp record_view(socket, poet, entry) do
    if connected?(socket) and entry && socket.assigns.current_user.id == poet.user_id do
      case Journal.mark_owner_viewed(entry) do
        {:ok, updated} -> %{entry | owner_viewed_at: updated.owner_viewed_at}
        _ -> entry
      end
    else
      entry
    end
  end

  # The question under the entry, if the cadence says there should be one.
  defp assign_prompt(socket, poet, entry) do
    prompt =
      if entry && socket.assigns.current_user.id == poet.user_id do
        Preferences.prompt_for_entry(poet, entry)
      end

    socket
    |> assign(:prompt, prompt)
    |> assign(:prompt_answer, Preferences.EntryPrompt.answered_option(prompt))
  end

  defp assign_stay(socket, _poet, nil), do: assign(socket, stay_id: nil, stay_count: 0)

  defp assign_stay(socket, poet, stay_id) do
    count = poet.id |> Guide.list_places(path_point_id: stay_id) |> length()
    assign(socket, stay_id: stay_id, stay_count: count)
  end

  defp guide_url(nil), do: ~p"/guide"
  defp guide_url(stay_id), do: ~p"/guide?#{[stay: stay_id, view: "itinerary"]}"

  # Places pins only when the reader is on the Places spread; on Today the
  # map shows the journey, and the two would fight for the viewport.
  defp map_places(%{assigns: %{spread: %{key: "places"}, places: places}}), do: places
  defp map_places(_socket), do: []

  defp places_spread?(%{spread: %{key: "places"}}), do: true
  defp places_spread?(_assigns), do: false

  defp finds_spread?(%{spread: %{key: "finds"}}), do: true
  defp finds_spread?(_assigns), do: false

  # An excursion has no coordinates to pin; its journey is a drawing, and it
  # takes the map's place at the top of the page.
  defp assign_route(socket, poet, entry) do
    case entry && Topics.excursion_of(entry) do
      %{topic_id: id} = excursion when is_integer(id) ->
        assign(socket, :route, Topics.journey_diagram(poet.id, excursion))

      _ ->
        assign(socket, :route, nil)
    end
  end

  defp finds_guide_url(entry) do
    case Topics.excursion_of(entry) do
      %{topic_id: topic_id} when is_integer(topic_id) -> ~p"/guide?#{[topic: topic_id]}"
      _ -> nil
    end
  end

  defp my_reactions(nil, _user), do: MapSet.new()

  defp my_reactions(entry, user) do
    entry.reactions
    |> Enum.filter(&(&1.user_id == user.id and &1.visibility == "private"))
    |> Enum.map(& &1.kind)
    |> MapSet.new()
  rescue
    # reactions not preloaded
    _ ->
      Journal.list_reactions(entry.id, "private")
      |> Enum.filter(&(&1.user_id == user.id))
      |> Enum.map(& &1.kind)
      |> MapSet.new()
  end

  ## Events

  @impl true
  def handle_event("push_" <> _ = event, params, socket),
    do: TravelingPoetWeb.PushNotifications.handle_event(event, params, socket)

  @impl true
  def handle_event("toggle_chat", _params, socket) do
    {:noreply, assign(socket, :sidebar_open, !socket.assigns.sidebar_open)}
  end

  @impl true
  def handle_event("telegram_" <> _ = event, params, socket),
    do: TravelingPoetWeb.TelegramPairing.handle_event(event, params, socket)

  @impl true
  def handle_event("toggle_mobile_chat", _params, socket) do
    {:noreply, assign(socket, :mobile_chat_open, !socket.assigns.mobile_chat_open)}
  end

  @impl true
  def handle_event("validate_attachment", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_attachment", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :chat_attachment, ref)}
  end

  @impl true
  def handle_event("prompt_answer", %{"option" => option_id}, socket) do
    %{prompt: prompt, poet: poet, entry: entry} = socket.assigns

    case Preferences.answer_prompt(prompt, option_id, poet.id, entry) do
      {:ok, {prompt, _preference}} ->
        {:noreply,
         socket
         |> assign(:prompt, prompt)
         |> assign(:prompt_answer, Preferences.EntryPrompt.answered_option(prompt))}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("prompt_undo", _params, socket) do
    %{prompt: prompt, poet: poet} = socket.assigns

    case Preferences.undo_answer(prompt, poet.id) do
      {:ok, prompt} ->
        {:noreply, socket |> assign(:prompt, prompt) |> assign(:prompt_answer, nil)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("prompt_dismiss", _params, socket) do
    {:ok, _} = Preferences.dismiss_prompt(socket.assigns.prompt)
    {:noreply, assign(socket, :prompt, nil)}
  end

  @impl true
  def handle_event("react", %{"kind" => kind}, socket) do
    if entry = socket.assigns.entry do
      Journal.toggle_reaction(entry.id, socket.assigns.user.id, kind, "private")
      entry = Journal.preload_entry(Journal.get_entry!(entry.id))

      {:noreply,
       socket
       |> assign(:entry, entry)
       |> assign(:my_reactions, my_reactions(entry, socket.assigns.user))}
    else
      {:noreply, socket}
    end
  end

  ## Feedback markers

  @impl true
  def handle_event("pick_marker", %{"kind" => kind}, socket) do
    active =
      if kind != socket.assigns.active_marker and kind in Marker.kinds(), do: kind, else: nil

    {:noreply, assign(socket, :active_marker, active)}
  end

  # The hook's payload is whatever the browser sent; a malformed one is
  # dropped, never a crash. The marker stays in hand so several can be
  # dropped in a row.
  @impl true
  def handle_event("marker_add", params, socket) do
    with %{} = entry <- socket.assigns.entry,
         {:ok, marker} <- Markers.add_marker(socket.assigns.user, entry, params) do
      # The id goes back so the hook can open the note box on an "Other
      # feedback" marker it just placed.
      {:reply, %{id: marker.id}, assign_markers(socket, entry)}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("marker_note", %{"id" => id, "note" => note}, socket) do
    Markers.update_note(socket.assigns.user.id, id, note)
    {:noreply, assign_markers(socket, socket.assigns.entry)}
  end

  @impl true
  def handle_event("marker_remove", %{"id" => id}, socket) do
    Markers.remove_marker(socket.assigns.user.id, id)
    {:noreply, assign_markers(socket, socket.assigns.entry)}
  end

  ## Chat wiring (ported from alice-in-goals DashboardLive)

  @impl true
  def handle_info({:chat_send, message}, socket) do
    handle_info({:chat_send, message, false}, socket)
  end

  @impl true
  def handle_info({:chat_send, message, has_attachment?}, socket) do
    user = socket.assigns.user
    socket = socket |> mark_activity() |> assign(:last_sent, message)

    cond do
      !(user.sprite_url && user.gateway_token) ->
        send_update(ChatSidebarComponent,
          id: "chat-sidebar",
          stream_error: "Your poet isn't ready yet."
        )

        {:noreply, socket}

      Credits.exhausted?(user, socket.assigns.poet) ->
        send_update(ChatSidebarComponent,
          id: "chat-sidebar",
          stream_error: "Your poet is out of credits — top up in Settings."
        )

        {:noreply, socket}

      not Usage.within_budget?(user, "chat_turn") ->
        send_update(ChatSidebarComponent,
          id: "chat-sidebar",
          stream_error: "Your poet is resting until tomorrow (daily limit reached)."
        )

        {:noreply, socket}

      has_attachment? ->
        Usage.record(user.id, "chat_turn")
        consume_and_dispatch_attachment(socket, message)

      true ->
        Usage.record(user.id, "chat_turn")
        dispatch_to_gateway(socket, message)
    end
  end

  @impl true
  def handle_info({:retry_chat_send, message}, socket) do
    socket = ensure_gateway_connected(socket)
    pid = socket.assigns.gateway_socket_pid

    if pid do
      GatewaySocket.send_message(pid, message)
    else
      send_update(ChatSidebarComponent,
        id: "chat-sidebar",
        stream_error: "Could not reach your poet. Please try again."
      )
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:gateway_event, {:text_delta, delta}}, socket) do
    send_update(ChatSidebarComponent, id: "chat-sidebar", stream_delta: delta)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:gateway_event, {:text_replace, text}}, socket) do
    send_update(ChatSidebarComponent, id: "chat-sidebar", stream_replace: text)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:gateway_event, {:done, response_id}}, socket) do
    send_update(ChatSidebarComponent, id: "chat-sidebar", stream_done: response_id)
    {:noreply, socket |> mark_activity() |> resend_held()}
  end

  @impl true
  def handle_info({:gateway_event, {:error, reason}}, socket) do
    if holdable?(reason, socket) do
      send_update(ChatSidebarComponent, id: "chat-sidebar", stream_held: true)
      {:noreply, assign(socket, :held_message, socket.assigns.last_sent)}
    else
      send_update(ChatSidebarComponent,
        id: "chat-sidebar",
        stream_error: friendly_error(reason, socket)
      )

      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:gateway_event, :connected}, socket) do
    send_update(ChatSidebarComponent, id: "chat-sidebar", connection_status: :connected)

    socket =
      socket
      |> assign(:sprite_status, :running)
      |> maybe_fire_agent_onboard()
      |> refresh_first_entry()

    {:noreply, socket}
  end

  @impl true
  def handle_info({:provision_step, step}, socket) do
    {:noreply, assign(socket, :provision_step, step)}
  end

  @impl true
  def handle_info({:telegram_paired, _} = msg, socket),
    do: TravelingPoetWeb.TelegramPairing.handle_info(msg, socket)

  @impl true
  def handle_info({:gateway_event, :disconnected}, socket) do
    send_update(ChatSidebarComponent, id: "chat-sidebar", connection_status: :reconnecting)
    {:noreply, assign(socket, sprite_status: :reconnecting)}
  end

  @impl true
  def handle_info({:gateway_event, _}, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:sprite_waking, waking}, socket) do
    send_update(ChatSidebarComponent, id: "chat-sidebar", sprite_waking: waking)
    status = if waking, do: :waking, else: :running
    {:noreply, assign(socket, :sprite_status, status)}
  end

  @impl true
  def handle_info({:sprite_provisioned, result}, socket) do
    user = Accounts.get_user!(socket.assigns.user.id)
    poet = Poets.get_poet_by_user(user.id)

    send_update(ChatSidebarComponent, id: "chat-sidebar", sprite_provisioned: result)
    Process.send_after(self(), :keepalive, @keepalive_interval_ms)

    if user.sprite_url && user.gateway_token do
      connect_gateway_socket(user)
    end

    {:noreply,
     socket
     |> assign(:user, user)
     |> assign(:poet, poet)
     |> assign(:provision_step, nil)
     |> assign(:sprite_status, :running)
     |> refresh_first_entry()}
  end

  @impl true
  def handle_info({:credits_updated, _balance}, socket) do
    user = Accounts.get_user!(socket.assigns.user.id)

    {:noreply,
     socket
     |> assign(:user, user)
     |> assign(:current_user, user)
     |> assign(:credits_low, Credits.low?(user, socket.assigns.poet))}
  end

  @impl true
  def handle_info({:journal_published, entry_id}, socket) do
    poet = Poets.get_poet_by_user(socket.assigns.user.id)
    current = socket.assigns.entry

    if current && current.id == entry_id do
      {:noreply,
       socket
       |> assign(:poet, poet)
       |> assign_journal(poet, current.entry_date)
       |> put_flash(:info, "#{poet.name} revised this entry.")}
    else
      {:noreply,
       socket
       |> assign(:poet, poet)
       |> assign_journal(poet, nil)
       |> assign(:showcase, nil)
       |> assign(:first_entry, :done)
       |> resend_held()
       |> put_flash(:info, "#{poet.name} published a new journal entry!")}
    end
  end

  # Another poet published: the tour's numbers and drawings moved on. The map
  # div is phx-update="ignore", so the hook hears about it by event.
  @impl true
  def handle_info({:journal_published, _poet_id, _entry_id}, socket) do
    if awaiting_first_entry?(socket.assigns) do
      showcase = Showcase.build(socket.assigns.poet)

      {:noreply,
       socket
       |> assign(:showcase, showcase)
       |> push_event("tour:update", Showcase.tour_payload(showcase))}
    else
      {:noreply, socket}
    end
  end

  # The poet re-put an entry after feedback. Stay on the page being read.
  @impl true
  def handle_info({:journal_revised, entry_id}, socket) do
    poet = Poets.get_poet_by_user(socket.assigns.user.id)
    current = socket.assigns.entry
    socket = assign(socket, :poet, poet)

    if current && current.id == entry_id do
      {:noreply,
       socket
       |> assign_journal(poet, current.entry_date)
       |> put_flash(:info, "#{poet.name} revised this entry.")}
    else
      {:noreply, assign_journal(socket, poet, current && current.entry_date)}
    end
  end

  @impl true
  def handle_info(:keepalive, socket) do
    socket =
      if recently_active?(socket), do: refresh_hold(socket), else: release_hold(socket)

    Process.send_after(self(), :keepalive, @keepalive_interval_ms)
    {:noreply, socket}
  end

  @impl true
  def handle_info(:setup_refresh, socket) do
    if awaiting_first_entry?(socket.assigns) do
      user = Accounts.get_user!(socket.assigns.user.id)
      poet = Poets.get_poet_by_user(user.id) || socket.assigns.poet

      sprite_status =
        cond do
          # don't downgrade a live status the gateway already reported
          socket.assigns.sprite_status in [:running, :waking, :reconnecting] ->
            socket.assigns.sprite_status

          user.sprite_provisioned ->
            :provisioned

          true ->
            :not_provisioned
        end

      Process.send_after(self(), :setup_refresh, @setup_refresh_ms)

      socket =
        socket
        |> assign(:user, user)
        |> assign(:poet, poet)
        |> assign(:sprite_status, sprite_status)
        |> assign_journal(poet, nil)
        |> refresh_first_entry()

      # A step broadcast that never arrived (dropped socket) would otherwise
      # leave the card pointing at a stage that finished long ago.
      socket =
        if user.sprite_provisioned, do: assign(socket, :provision_step, nil), else: socket

      # The turn that turned our message away may have ended without a :done
      # reaching this tab; once the attempt window is over, let it go out.
      socket =
        if socket.assigns.first_entry == :in_flight, do: socket, else: resend_held(socket)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(msg, socket) do
    Logger.debug("JournalLive received unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  ## Render

  # Two waits, two gates. Before the sprite exists there is nothing to talk
  # to, so the chat stays out and the column shows the setup card. Once the
  # sprite is reachable the real page renders with a placeholder where the
  # first entry will land, and the chat opens so a hello can go in early.
  # Beta feedback on the old single screen: people gave up before anything
  # appeared. The gateway wiring runs underneath so /onboard still auto-fires.
  defp awaiting_first_entry?(assigns), do: assigns.entries == []
  defp provisioning?(assigns), do: assigns.sprite_status == :not_provisioned

  # Whole minutes since the poet was created. The waiting cards re-render every
  # @setup_refresh_ms, so this ticks along on its own and the wait shows its own
  # length instead of a promise the app can't keep: measured across the fleet,
  # setup ran 1.7–20 minutes and the first entry landed anywhere from 4 minutes
  # to (twice) the following day's scheduled run.
  defp setup_minutes(nil), do: 0

  defp setup_minutes(poet) do
    poet.inserted_at
    |> NaiveDateTime.diff(NaiveDateTime.utc_now())
    |> abs()
    |> div(60)
  end

  # The provisioning chain as four things a reader can picture. Each stage
  # covers a run of `Provisioner.steps/0`, in order.
  @setup_stages [
    {"Renting a room", [:create_sprite, :make_public]},
    {"Installing the writing desk", [:install_openclaw]},
    {"Packing notebook, pens and maps",
     [:write_config, :write_env, :write_workspace, :write_tpoet_plugin]},
    {"Opening the door", [:ensure_gateway_service, :pair_device, :get_sprite_url]}
  ]

  # `nil` means no step broadcast has reached this tab (fresh mount, dropped
  # socket): every stage shows as pending under one "working" row rather than
  # pointing at a stage that may be long finished.
  defp stage_states(nil), do: Enum.map(@setup_stages, fn {label, _} -> {label, :pending} end)

  defp stage_states(step) do
    steps = TravelingPoet.Provisioner.steps()
    at = Enum.find_index(steps, &(&1 == step)) || 0

    Enum.map(@setup_stages, fn {label, stage_steps} ->
      first = Enum.find_index(steps, &(&1 == hd(stage_steps)))
      last = Enum.find_index(steps, &(&1 == List.last(stage_steps)))

      state =
        cond do
          at > last -> :done
          at >= first -> :active
          true -> :pending
        end

      {label, state}
    end)
  end

  attr :poet, :any, required: true
  attr :provision_step, :atom, default: nil

  defp setup_card(assigns) do
    assigns = assign(assigns, :stages, stage_states(assigns.provision_step))

    ~H"""
    <article id="setup-card" class="notebook-page mt-6">
      <h2 class="notebook-title">Setting up {@poet.name}'s travel desk</h2>
      <ol class="mt-4 space-y-2 text-sm">
        <li
          :for={{label, state} <- @stages}
          class={["flex items-center gap-3", state == :pending && "opacity-50"]}
        >
          <.stage_mark state={state} />
          <span>{label}</span>
        </li>
        <li :if={is_nil(@provision_step)} class="flex items-center gap-3">
          <.stage_mark state={:active} />
          <span>Working on it</span>
        </li>
      </ol>
      <p class="text-sm opacity-70 mt-4">
        This usually takes 2 to 20 minutes. You can close this page; {@poet.name} keeps working
        and this page updates on its own.
      </p>
      <.elapsed_note poet={@poet} />
    </article>
    """
  end

  attr :state, :atom, required: true

  defp stage_mark(assigns) do
    ~H"""
    <span :if={@state == :done} class="text-success inline-flex w-5 justify-center">
      <.icon name="hero-check" class="size-4" />
    </span>
    <span :if={@state == :active} class="loading loading-dots loading-sm opacity-50 w-5"></span>
    <span :if={@state == :pending} class="inline-block w-5 text-center opacity-40">-</span>
    """
  end

  attr :poet, :any, required: true

  defp elapsed_note(assigns) do
    assigns = assign(assigns, :minutes, setup_minutes(assigns.poet))

    ~H"""
    <p :if={@minutes >= 1} class="text-sm opacity-60 mt-2">
      Yours started {@minutes} {if @minutes == 1, do: "minute", else: "minutes"} ago.
      <span :if={@minutes >= 20}>
        This one is taking longer than usual. Nothing is lost; the poet is still at it.
      </span>
    </p>
    """
  end

  attr :poet, :any, required: true
  attr :first_entry, :atom, required: true

  # Where the first entry will land, in the notebook's own clothes, so the
  # reader sees the shape of what is coming rather than an empty column.
  defp first_entry_placeholder(assigns) do
    ~H"""
    <article id="first-entry-placeholder" class="notebook-page mt-6">
      <h2 class="notebook-title">
        The first entry
        <span class="notebook-date ml-2">
          {Calendar.strftime(Date.utc_today(), "%B %-d, %Y")}
        </span>
      </h2>
      <div class="mt-3 text-sm space-y-2">
        <p :if={@first_entry in [:starting, :waiting_for_sprite, :done]}>
          {@poet.name} is awake and about to open the notebook. The first page usually takes
          5 to 12 minutes.
        </p>
        <p :if={@first_entry == :in_flight} class="flex items-start gap-2">
          <span class="loading loading-dots loading-sm opacity-50 mt-1"></span>
          <span>
            {@poet.name} is writing the first entry. This usually takes 5 to 12 minutes; the
            drawing comes last. You can read along in the chat.
          </span>
        </p>
        <p :if={@first_entry == :retry_pending}>
          The first attempt did not produce a page. {@poet.name} will try again within {FirstEntry.retry_after_minutes()} minutes. Nothing is lost.
        </p>
        <p :if={@first_entry == :exhausted}>
          {@poet.name} could not finish the first entry after {FirstEntry.max_attempts()} tries.
          The daily run will try again tomorrow.
        </p>
        <p class="opacity-70">
          You can close this page; {@poet.name} keeps working and this page updates on its own.
        </p>
      </div>
      <.elapsed_note poet={@poet} />
    </article>
    """
  end

  attr :showcase, :map, required: true

  # The cards the tour turns: one per public poet, first one open. The hook
  # toggles `hidden`, counts the numbers up and turns the drawing carousel to
  # each stop as the map draws the route. Private poets are grey dots on the
  # map and nothing here.
  defp journey_cards(assigns) do
    ~H"""
    <div id="journey-tour-cards" class="mt-3">
      <p :if={@showcase.poets != []} class="text-sm opacity-70" id="journey-totals">
        {@showcase.totals.poets} {ngettext("poet", "poets", @showcase.totals.poets)} on the road: {@showcase.totals.entries} entries, {@showcase.totals.places} places found, {@showcase.totals.countries} countries, {@showcase.totals.drawings} drawings.
      </p>
      <p :if={@showcase.poets == []} class="text-sm opacity-70">
        Yours will be the first poet on the road.
      </p>
      <div
        :if={length(@showcase.poets) > 1}
        class="spread-picker mt-1"
        role="tablist"
        aria-label="Poets on the road"
      >
        <button
          :for={{p, idx} <- Enum.with_index(@showcase.poets)}
          type="button"
          role="tab"
          class="spread-chip"
          data-tour-pick={p.slug}
          aria-selected={to_string(idx == 0)}
        >
          <img :if={p.avatar} src={p.avatar} alt="" class="spread-chip-avatar" />
          <span :if={!p.avatar} class="spread-chip-avatar spread-chip-initial">
            {String.first(p.name)}
          </span>
          <span class="spread-chip-text">
            <b>{p.name}</b>
            <small>{p.current.name}</small>
          </span>
        </button>
      </div>
      <article
        :for={{p, idx} <- Enum.with_index(@showcase.poets)}
        data-tour-poet={p.slug}
        hidden={idx != 0}
        class="notebook-page tour-card mt-2"
        aria-label={"#{p.name}'s journey"}
      >
        <div class="flex items-center gap-3">
          <img :if={p.avatar} src={p.avatar} alt="" class="w-10 h-10 rounded-full object-cover" />
          <div>
            <b>{p.name}</b>
            <span class="text-sm opacity-70">
              on the road for {p.stats.days} {ngettext("day", "days", p.stats.days)}, now in {p.current.name}
            </span>
          </div>
        </div>
        <div class="tour-stats">
          <div :for={{label, key} <- tour_stat_keys()} class="tour-stat">
            <b data-tour-count data-count={p.stats[key]}>{p.stats[key]}</b>
            <span>{label}</span>
          </div>
        </div>
        <div :if={Enum.any?(p.stops, & &1.media)} class="tour-carousel" data-tour-carousel>
          <div class="tour-slides">
            <div
              :for={{s, i} <- Enum.with_index(p.stops)}
              :if={s.media}
              data-tour-stop={"#{p.slug}:#{i}"}
              hidden
              class="tour-slide"
            >
              <.section section={%{kind: "illustration"}} media={s.media} />
              <p class="tour-stop-caption">
                {s.place}, {Calendar.strftime(Date.from_iso8601!(s.date), "%B %-d")}
              </p>
            </div>
          </div>
          <div class="tour-carousel-nav" role="group" aria-label="Drawings along the way">
            <button
              type="button"
              class="btn btn-ghost btn-xs"
              data-tour-prev
              aria-label="Previous drawing"
            >
              <.icon name="hero-chevron-left" class="size-4" />
            </button>
            <span class="tour-dots">
              <button
                :for={{s, i} <- Enum.with_index(p.stops)}
                :if={s.media}
                type="button"
                class="tour-dot"
                data-tour-dot={i}
                aria-label={"Drawing from #{s.place}"}
              ></button>
            </span>
            <button
              type="button"
              class="btn btn-ghost btn-xs"
              data-tour-next
              aria-label="Next drawing"
            >
              <.icon name="hero-chevron-right" class="size-4" />
            </button>
          </div>
        </div>
        <a href={p.latest_url} class="link text-sm inline-block mt-3">
          Read {p.name}'s latest page
        </a>
      </article>
      <p :if={@showcase.anonymous != []} class="text-xs opacity-50 mt-2">
        Grey dots are poets whose journals are private.
      </p>
    </div>
    """
  end

  defp tour_stat_keys do
    [
      {"entries", :entries},
      {"places found", :places},
      {"countries", :countries},
      {"drawings", :drawings}
    ]
  end

  attr :poet, :any, required: true
  attr :user, :any, required: true
  attr :push, :map, required: true
  attr :telegram, :map, required: true

  defp waiting_tips(assigns) do
    ~H"""
    <section id="waiting-tips" class="mt-6 rounded-xl border border-base-300 p-4 space-y-4">
      <h3 class="font-semibold">While you wait</h3>
      <.telegram_tip telegram={@telegram} user={@user} poet={@poet} />
      <.push_tip push={@push} poet={@poet} />
    </section>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={assigns[:current_user]}
      credits_low={assigns[:credits_low]}
      active_tab={:journal}
      wide
    >
      <div class="flex h-[calc(100vh-4rem)] gap-4">
        <div class="journal-column flex-1 min-w-0 overflow-y-auto pr-1">
          <div
            :if={Credits.exhausted?(@user, @poet)}
            class="alert alert-warning text-sm mb-3"
            id="credits-exhausted-banner"
          >
            <.icon name="hero-moon" class="size-5" />
            <span>
              {@poet.name} is resting — out of credits.
              <.link navigate={~p"/settings"} class="link font-semibold">Top up</.link>
            </span>
          </div>
          <div class="flex items-center gap-3 mb-3">
            <img
              :if={@poet.avatar_url}
              src={@poet.avatar_url}
              class="w-12 h-12 rounded-full object-cover"
              alt={@poet.name}
            />
            <div>
              <h1 class="text-xl font-semibold">{@poet.name}</h1>
              <p class="text-sm opacity-70">
                <span :if={@poet.current_place_name}>
                  📍 {@poet.current_place_name}
                </span>
                <span :if={@sprite_status == :not_provisioned} class="text-warning">
                  preparing to set out
                </span>
              </p>
            </div>
            <a
              :if={@entries != []}
              href={~p"/journal/book"}
              target="_blank"
              class="ml-auto btn btn-ghost btn-sm"
              title="The whole journal as a printable book"
            >
              <.icon name="hero-book-open" class="size-4" /> Book
            </a>
            <button
              :if={!provisioning?(assigns)}
              phx-click="toggle_chat"
              class={[
                "hidden lg:inline-flex btn btn-ghost btn-sm",
                @entries == [] && "ml-auto"
              ]}
              aria-label="Toggle chat"
            >
              💬 {if @sidebar_open, do: "Hide chat", else: "Chat"}
            </button>
          </div>

          <.excursion_route
            :if={!awaiting_first_entry?(assigns) and not is_nil(@route) and !finds_spread?(assigns)}
            diagram={@route}
            title={"#{@poet.name}'s journey through this topic"}
          />

          <div
            :if={!awaiting_first_entry?(assigns) and !places_spread?(assigns) and is_nil(@route)}
            id="poet-map"
            phx-hook="PoetMap"
            phx-update="ignore"
            class="w-full h-64 rounded-xl border border-base-300 z-0"
            data-points={Jason.encode!(map_points(@path_points, @poet, @entry, []))}
          >
          </div>

          <.push_nudge push={@push} poet={@poet} entry={@entry} />

          <.setup_card :if={provisioning?(assigns)} poet={@poet} provision_step={@provision_step} />
          <.first_entry_placeholder
            :if={awaiting_first_entry?(assigns) and !provisioning?(assigns)}
            poet={@poet}
            first_entry={@first_entry}
          />
          <.waiting_tips
            :if={awaiting_first_entry?(assigns)}
            poet={@poet}
            user={@user}
            push={@push}
            telegram={@telegram}
          />

          <section :if={awaiting_first_entry?(assigns) and @showcase} id="meanwhile" class="mt-8">
            <h3 class="font-semibold">In the meantime</h3>
            <p class="text-sm opacity-70 mb-3">
              <span :if={@showcase.poets != []}>
                Other poets are already out on the road. This is where they have been, what they
                drew and what they found, one poet at a time. Your own, {@poet.name}, is the red ring.
              </span>
              <span :if={@showcase.poets == []}>
                Here is where {@poet.name} sets out from. Yours will be the first poet on the road.
              </span>
            </p>
            <div
              id="journey-tour"
              phx-hook="JourneyTour"
              phx-update="ignore"
              data-cards="journey-tour-cards"
              class="w-full h-64 rounded-xl border border-base-300 z-0"
              data-tour={Jason.encode!(Showcase.tour_payload(@showcase))}
            >
            </div>
            <.journey_cards showcase={@showcase} />
          </section>

          <div :if={@entry} class="spread-wrap">
            <.spread_tabs
              spreads={@spreads}
              active={@spread.key}
              patch={&spread_path(@entry, &1)}
              chat={!provisioning?(assigns)}
              chat_open={@sidebar_open}
            />
            <.places_spread
              :if={places_spread?(assigns)}
              id={"places-#{@entry.id}"}
              entry={@entry}
              day={Journal.journey_day(@entry, @journey_start)}
              spread={@spread}
              poet={@poet}
              place_media={@place_media}
              guide_url={guide_url(@stay_id)}
              stay_count={@stay_count}
            >
              <:map>
                <div
                  id="poet-map"
                  phx-hook="PoetMap"
                  phx-update="ignore"
                  class="taped-map-canvas z-0"
                  data-points={Jason.encode!(map_points(@path_points, @poet, @entry, @places))}
                >
                </div>
              </:map>
              <:controls>
                <.link
                  :for={{label, date} <- entry_nav(@entries, @entry)}
                  navigate={~p"/journal/#{date}"}
                  class="btn btn-ghost btn-xs"
                >
                  {label}
                </.link>
              </:controls>
            </.places_spread>
            <.finds_spread
              :if={finds_spread?(assigns)}
              id={"finds-#{@entry.id}"}
              entry={@entry}
              day={Journal.journey_day(@entry, @journey_start)}
              spread={@spread}
              poet={@poet}
              find_media={@find_media}
              guide_url={finds_guide_url(@entry)}
            >
              <:controls>
                <.link
                  :for={{label, date} <- entry_nav(@entries, @entry)}
                  navigate={~p"/journal/#{date}"}
                  class="btn btn-ghost btn-xs"
                >
                  {label}
                </.link>
              </:controls>
            </.finds_spread>
            <.entry_spread
              :if={!places_spread?(assigns) and !finds_spread?(assigns)}
              id={"entry-#{@entry.id}"}
              entry={@entry}
              day={Journal.journey_day(@entry, @journey_start)}
              spread={@spread}
              media={@entry_media}
              place_links={place_links(@places, ~p"/journal/#{Date.to_iso8601(@entry.entry_date)}")}
              spot_media={@spot_media}
              phx-hook="Markers"
              data-active-marker={@active_marker}
              data-markers={@markers_json}
              data-marker-icons={icons_json()}
            >
              <:controls>
                <.marker_menu active={@active_marker} />
                <.link
                  :for={{label, date} <- entry_nav(@entries, @entry)}
                  navigate={~p"/journal/#{date}"}
                  class="btn btn-ghost btn-xs"
                >
                  {label}
                </.link>
              </:controls>
              <:right_footer>
                <div :if={@prompt} class="border-t border-base-300 pt-3 mt-4">
                  <div :if={is_nil(@prompt_answer)}>
                    <p class="text-sm font-medium mb-2">{@prompt.question}</p>
                    <div class="flex flex-wrap items-center gap-2">
                      <button
                        :for={option <- Preferences.EntryPrompt.items(@prompt)}
                        phx-click="prompt_answer"
                        phx-value-option={option["id"]}
                        class="btn btn-sm btn-outline"
                      >
                        {option["label"]}
                      </button>
                      <button phx-click="prompt_dismiss" class="btn btn-ghost btn-xs opacity-50">
                        not now
                      </button>
                    </div>
                  </div>
                  <div :if={@prompt_answer} class="flex items-center gap-2 text-sm">
                    <span>
                      Got it — {@poet.name} will keep that in mind.
                    </span>
                    <button phx-click="prompt_undo" class="btn btn-ghost btn-xs">undo</button>
                    <.link navigate={~p"/settings"} class="link text-xs opacity-60">
                      what your poet has learned
                    </.link>
                  </div>
                </div>

                <div class="border-t border-base-300 pt-3 mt-4">
                  <div class="flex flex-wrap items-center gap-2">
                    <span class="text-sm opacity-60 mr-1 whitespace-nowrap">Tell your poet:</span>
                    <button
                      :for={{kind, emoji} <- reaction_kinds()}
                      phx-click="react"
                      phx-value-kind={kind}
                      class={[
                        "btn btn-sm",
                        if(MapSet.member?(@my_reactions, kind), do: "btn-primary", else: "btn-ghost")
                      ]}
                      title={kind}
                    >
                      {emoji}
                    </button>
                  </div>
                  <p class="text-xs opacity-40 mt-1">
                    private feedback — shapes what your poet seeks out next
                  </p>
                </div>
              </:right_footer>
            </.entry_spread>
          </div>
        </div>

        <.live_component
          :if={!provisioning?(assigns)}
          module={TravelingPoetWeb.ChatSidebarComponent}
          id="chat-sidebar"
          user={@user}
          sidebar_open={@sidebar_open}
          mobile_chat_open={@mobile_chat_open}
          first_entry={@first_entry}
          chat_attachment_upload={@uploads.chat_attachment}
        />

        <button
          :if={!provisioning?(assigns) and !@mobile_chat_open}
          phx-click="toggle_mobile_chat"
          class="lg:hidden fixed bottom-[calc(1.25rem+env(safe-area-inset-bottom))] right-5 z-40 btn btn-primary btn-circle btn-lg shadow-lg"
          aria-label="Open chat"
        >
          💬
        </button>
      </div>
    </Layouts.app>
    """
  end

  defp reaction_kinds do
    [{"love", "❤️"}, {"inspiring", "✨"}, {"want_more", "➕"}, {"not_for_me", "🤷"}]
  end

  # `entry` focuses the map on the day you are actually reading. Without it the
  # map only ever knew the poet's path and where it is NOW, so paging back
  # through the journal left it sitting on the current city while the page
  # talked about somewhere else entirely.
  defp map_points(path_points, poet, entry, places) do
    points =
      Enum.map(path_points, fn p ->
        %{lat: p.lat, lng: p.lng, name: p.place_name}
      end)

    current =
      if poet.current_lat do
        %{lat: poet.current_lat, lng: poet.current_lng, name: poet.current_place_name}
      end

    planned =
      if TravelingPoet.Poets.Poet.mode(poet) == "scout" do
        Poets.list_stops(poet.id)
        |> Enum.filter(&is_nil(&1.visited_at))
        |> Enum.map(fn s -> %{lat: s.lat, lng: s.lng, name: s.place_name} end)
      else
        []
      end

    %{
      path: points,
      current: current,
      planned: planned,
      poet: poet.name,
      focus: focus_point(entry),
      places: Guide.map_payload(places, poet.name)
    }
  end

  defp focus_point(%{lat: lat, lng: lng} = entry) when is_number(lat) and is_number(lng) do
    %{lat: lat, lng: lng, name: entry.place_name, date: Date.to_iso8601(entry.entry_date)}
  end

  defp focus_point(_), do: nil

  # Closing the tab releases the sprite within seconds instead of leaving the
  # task to run out its expiry.
  @impl true
  def terminate(_reason, socket) do
    release_hold(socket)
    :ok
  end

  ## Chat helpers (ported from alice-in DashboardLive)

  # Activity starts the hold right away rather than waiting for the next
  # keepalive tick; the tick then keeps it refreshed for the active window.
  defp mark_activity(socket) do
    socket = assign(socket, :last_activity_at, System.monotonic_time(:millisecond))
    if socket.assigns.hold_live, do: socket, else: refresh_hold(socket)
  end

  defp refresh_hold(%{assigns: %{user: %{sprite_name: name}, keepalive_task: task}} = socket)
       when is_binary(name) and name != "" do
    Task.start(fn -> SpriteHold.put(name, task, @keepalive_task_expire) end)
    assign(socket, :hold_live, true)
  end

  defp refresh_hold(socket), do: socket

  defp release_hold(%{assigns: %{hold_live: true, user: user, keepalive_task: task}} = socket) do
    Task.start(fn -> SpriteHold.delete(user.sprite_name, task) end)
    assign(socket, :hold_live, false)
  end

  defp release_hold(socket), do: socket

  # The gateway rejects a chat.send while another turn is running (e.g. the
  # auto-fired /onboard right after provisioning) with a bare "Chat error".
  # Translate it into something a user can act on.
  defp friendly_error(reason, socket) when is_binary(reason) do
    poet_name = (socket.assigns[:poet] && socket.assigns.poet.name) || "Your poet"

    if busy_rejection?(reason) do
      "#{poet_name} is mid-thought, probably writing to you right now. Give it a moment and resend."
    else
      reason
    end
  end

  defp friendly_error(reason, _socket), do: reason

  defp busy_rejection?(reason), do: is_binary(reason) and String.contains?(reason, "Chat error")

  # While the first entry is being written the gateway is busy for minutes,
  # and a hello sent into that is worth keeping rather than bouncing back at
  # the reader. One message at a time; it goes out when the turn ends.
  defp holdable?(reason, socket) do
    busy_rejection?(reason) and socket.assigns.first_entry == :in_flight and
      is_nil(socket.assigns.held_message) and is_binary(socket.assigns.last_sent)
  end

  defp resend_held(%{assigns: %{held_message: nil}} = socket), do: socket

  defp resend_held(%{assigns: %{held_message: message, user: user}} = socket) do
    socket = assign(socket, :held_message, nil)

    if user.sprite_url && user.gateway_token do
      send_update(ChatSidebarComponent, id: "chat-sidebar", stream_resent: true)
      {:noreply, socket} = dispatch_to_gateway(socket, message)
      socket
    else
      send_update(ChatSidebarComponent,
        id: "chat-sidebar",
        stream_error: "Your poet isn't ready yet."
      )

      socket
    end
  end

  defp refresh_first_entry(socket) do
    assign(socket, :first_entry, FirstEntry.status(socket.assigns.user, socket.assigns.poet))
  end

  defp recently_active?(socket) do
    case socket.assigns[:last_activity_at] do
      nil -> false
      t -> System.monotonic_time(:millisecond) - t < @keepalive_active_window_ms
    end
  end

  # The fast path for someone watching the setting-up screen: kick the first
  # entry off the moment the gateway connects. FirstEntry owns the decision
  # (already published? already in flight? out of attempts?) and the outcome
  # accounting, and its watchdog covers everyone who closed the tab — which
  # this screen explicitly invites them to do.
  defp maybe_fire_agent_onboard(socket) do
    user = socket.assigns.user

    case FirstEntry.ensure_started(user, socket.assigns.poet) do
      :started ->
        Logger.info("Auto-fired /onboard for user #{user.id}")
        socket

      _ ->
        socket
    end
  end

  defp dispatch_to_gateway(socket, message) do
    user = socket.assigns.user
    socket = socket |> assign(:last_sent, message) |> ensure_gateway_connected()
    pid = socket.assigns.gateway_socket_pid

    if pid do
      GatewaySocket.send_message(pid, message)
    else
      lv = self()
      sprite_name = user.sprite_name

      Task.start(fn ->
        send(lv, {:sprite_waking, true})

        case wake_sprite(sprite_name) do
          :ok -> send(lv, {:sprite_waking, false})
          {:error, _} -> send(lv, {:sprite_waking, false})
        end

        send(lv, {:retry_chat_send, message})
      end)
    end

    {:noreply, socket}
  end

  defp consume_and_dispatch_attachment(socket, message) do
    user = socket.assigns.user
    sprite_name = user.sprite_name
    entries = socket.assigns.uploads.chat_attachment.entries

    cond do
      entries == [] ->
        send_update(ChatSidebarComponent,
          id: "chat-sidebar",
          stream_error: "Attachment is missing — please pick a file again."
        )

        {:noreply, socket}

      Enum.any?(entries, &(not &1.done?)) ->
        send_update(ChatSidebarComponent,
          id: "chat-sidebar",
          stream_error: "Upload still in progress — please wait a moment and try again."
        )

        {:noreply, socket}

      true ->
        do_consume_and_dispatch(socket, message, sprite_name)
    end
  end

  defp do_consume_and_dispatch(socket, message, sprite_name) do
    user = socket.assigns.user

    [result | _] =
      consume_uploaded_entries(socket, :chat_attachment, fn %{path: path}, entry ->
        case SpriteUploads.push_to_workspace(sprite_name, path, entry.client_name) do
          {:ok, info} -> {:ok, info}
          {:error, reason} -> {:postpone, reason}
        end
      end) ++ [nil]

    case result do
      %{sprite_path: sprite_path, filename: filename, size: size} ->
        augmented = build_augmented_message(message, sprite_path, size)

        {:ok, msg} =
          Chat.create_message(%{
            user_id: user.id,
            role: "user",
            content: message_or_marker(message, sprite_path),
            attachments: %{
              "files" => [
                %{"filename" => filename, "size" => size, "sprite_path" => sprite_path}
              ]
            }
          })

        send_update(ChatSidebarComponent, id: "chat-sidebar", append_user_message: msg)

        dispatch_to_gateway(socket, augmented)

      nil ->
        send_update(ChatSidebarComponent,
          id: "chat-sidebar",
          stream_error: "Upload failed: no file consumed"
        )

        {:noreply, socket}
    end
  end

  defp message_or_marker("", sprite_path), do: "[Uploaded file: #{sprite_path}]"
  defp message_or_marker(text, _sprite_path), do: text

  defp build_augmented_message(text, sprite_path, size) do
    marker = "[Uploaded file: #{sprite_path} (size: #{format_bytes(size)})]"

    case String.trim(text) do
      "" -> marker
      _ -> "#{text}\n\n#{marker}"
    end
  end

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  defp connect_gateway_socket(user) do
    case GatewaySocketSupervisor.ensure_connected(user) do
      {:ok, pid} ->
        GatewaySocket.subscribe(pid)
        pid

      {:error, reason} ->
        Logger.warning("Failed to connect gateway socket: #{inspect(reason)}")
        nil
    end
  end

  defp ensure_gateway_connected(socket) do
    pid = socket.assigns.gateway_socket_pid

    if pid && Process.alive?(pid) do
      socket
    else
      user = socket.assigns.user
      new_pid = connect_gateway_socket(user)
      assign(socket, :gateway_socket_pid, new_pid)
    end
  end

  defp wake_sprite(sprite_name) do
    deadline = System.monotonic_time(:millisecond) + @wake_timeout_ms
    do_wake_sprite(sprite_name, deadline)
  end

  defp do_wake_sprite(sprite_name, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, :wake_timeout}
    else
      case SpritesClient.exec(sprite_name, "true") do
        {:ok, _} ->
          :ok

        {:error, _} ->
          Process.sleep(@wake_poll_ms)
          do_wake_sprite(sprite_name, deadline)
      end
    end
  end
end
