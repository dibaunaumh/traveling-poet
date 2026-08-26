defmodule TravelingPoetWeb.JournalLive do
  use TravelingPoetWeb, :live_view

  alias TravelingPoet.{Accounts, Chat, GatewaySocket, GatewaySocketSupervisor, Journal, Poets}
  alias TravelingPoet.{SpriteUploads, SpritesClient, Usage}
  alias TravelingPoet.Journal.Media
  alias TravelingPoetWeb.ChatSidebarComponent

  require Logger

  @keepalive_interval_ms 20_000
  @keepalive_active_window_ms 5 * 60 * 1000
  @wake_timeout_ms 30_000
  @wake_poll_ms 2_000
  @chat_attachment_max_bytes 25_000_000

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

            if user.sprite_provisioned do
              Process.send_after(self(), :keepalive, @keepalive_interval_ms)
            end

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
          |> assign(:sidebar_open, true)
          |> assign(:keepalive_ref, nil)
          |> assign(:last_activity_at, nil)
          |> assign(:sprite_status, initial_sprite_status)
          |> assign(:gateway_socket_pid, gateway_socket_pid)
          |> assign_journal(poet, nil)
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

        {:noreply, assign_journal(socket, poet, date)}
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

    media_map = entry_media_map(poet, entry)

    socket
    |> assign(:entries, entries)
    |> assign(:entry, entry)
    |> assign(:entry_media, media_map)
    |> assign(:my_reactions, my_reactions(entry, socket.assigns.current_user))
    |> assign(:path_points, Poets.list_path_points(poet.id))
  end

  defp entry_media_map(_poet, nil), do: %{}

  defp entry_media_map(_poet, entry) do
    entry.sections
    |> Enum.map(& &1.media_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Journal.get_media/1)
    |> Enum.reject(&is_nil/1)
    |> Map.new(&{&1.id, &1})
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
  def handle_event("toggle_chat", _params, socket) do
    {:noreply, assign(socket, :sidebar_open, !socket.assigns.sidebar_open)}
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

  ## Chat wiring (ported from alice-in-goals DashboardLive)

  @impl true
  def handle_info({:chat_send, message}, socket) do
    handle_info({:chat_send, message, false}, socket)
  end

  @impl true
  def handle_info({:chat_send, message, has_attachment?}, socket) do
    user = socket.assigns.user
    socket = mark_activity(socket)

    cond do
      !(user.sprite_url && user.gateway_token) ->
        send_update(ChatSidebarComponent,
          id: "chat-sidebar",
          stream_error: "Your poet isn't ready yet."
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
    keepalive_after_agent_turn(socket.assigns.user)
    {:noreply, mark_activity(socket)}
  end

  @impl true
  def handle_info({:gateway_event, {:error, reason}}, socket) do
    send_update(ChatSidebarComponent,
      id: "chat-sidebar",
      stream_error: friendly_error(reason, socket)
    )

    {:noreply, socket}
  end

  @impl true
  def handle_info({:gateway_event, :connected}, socket) do
    send_update(ChatSidebarComponent, id: "chat-sidebar", connection_status: :connected)

    socket =
      socket
      |> assign(:sprite_status, :running)
      |> maybe_fire_agent_onboard()

    {:noreply, socket}
  end

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
     |> assign(:sprite_status, :running)}
  end

  @impl true
  def handle_info({:journal_published, _entry_id}, socket) do
    poet = Poets.get_poet_by_user(socket.assigns.user.id)

    {:noreply,
     socket
     |> assign(:poet, poet)
     |> assign_journal(poet, nil)
     |> put_flash(:info, "#{poet.name} published a new journal entry!")}
  end

  @impl true
  def handle_info(:keepalive, socket) do
    user = socket.assigns.user

    if user.sprite_name && recently_active?(socket) do
      Task.start(fn ->
        SpritesClient.exec(user.sprite_name, hold_awake_cmd(25))
      end)
    end

    Process.send_after(self(), :keepalive, @keepalive_interval_ms)
    {:noreply, socket}
  end

  @impl true
  def handle_info(msg, socket) do
    Logger.debug("JournalLive received unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={assigns[:current_user]}>
      <div class="flex h-[calc(100vh-4rem)] gap-4">
        <div class="flex-1 min-w-0 overflow-y-auto pr-1">
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
                  · preparing to set out…
                </span>
              </p>
            </div>
            <div class="ml-auto">
              <.link navigate={~p"/settings"} class="btn btn-ghost btn-sm">Settings</.link>
            </div>
          </div>

          <div
            id="poet-map"
            phx-hook="PoetMap"
            phx-update="ignore"
            class="w-full h-64 rounded-xl border border-base-300 z-0"
            data-points={Jason.encode!(map_points(@path_points, @poet))}
          >
          </div>

          <article :if={@entry} class="notebook-page mt-6">
            <div class="flex items-center justify-between mb-2">
              <h2 class="notebook-title">
                {@entry.title || @entry.place_name || "Journal"}
                <span class="notebook-date ml-2">
                  {Calendar.strftime(@entry.entry_date, "%B %-d, %Y")}
                </span>
              </h2>
              <div class="flex gap-1">
                <.link
                  :for={{label, date} <- entry_nav(@entries, @entry)}
                  navigate={~p"/journal/#{date}"}
                  class="btn btn-ghost btn-xs"
                >
                  {label}
                </.link>
              </div>
            </div>

            <div :for={section <- @entry.sections} class="mb-6">
              <.section section={section} media={@entry_media[section.media_id]} />
            </div>

            <div class="flex items-center gap-2 border-t border-base-300 pt-3 mt-4">
              <span class="text-sm opacity-60 mr-1">Tell your poet:</span>
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
              <span class="text-xs opacity-40 ml-2">
                private feedback — shapes what your poet seeks out next
              </span>
            </div>
          </article>

          <div :if={is_nil(@entry)} class="mt-10 text-center opacity-70">
            <p :if={@sprite_status == :not_provisioned}>
              Your poet is being prepared — the first journal entry will appear here soon.
            </p>
            <p :if={@sprite_status != :not_provisioned}>
              No journal entries yet. Your poet is settling in — say hello in the chat!
            </p>
          </div>
        </div>

        <.live_component
          module={TravelingPoetWeb.ChatSidebarComponent}
          id="chat-sidebar"
          user={@user}
          sidebar_open={@sidebar_open}
          chat_attachment_upload={@uploads.chat_attachment}
        />
      </div>
    </Layouts.app>
    """
  end

  attr :section, :any, required: true
  attr :media, :any, default: nil

  defp section(%{section: %{kind: "illustration"}} = assigns) do
    ~H"""
    <figure :if={@media} class="taped-photo my-4">
      <img
        src={~p"/media/#{@media.id}"}
        alt={@media.alt_text || "illustration"}
        class="rounded-xl max-w-full shadow"
      />
      <figcaption class="text-xs opacity-60 mt-1 flex flex-wrap gap-x-3">
        <span :if={@media.alt_text}>{@media.alt_text}</span>
        <a
          :for={src <- Media.source_items(@media)}
          href={src["url"]}
          target="_blank"
          rel="noopener noreferrer nofollow"
          class="link"
        >
          {src["label"] || "see the real place"} ↗
        </a>
      </figcaption>
    </figure>
    """
  end

  defp section(assigns) do
    ~H"""
    <div class={@section.kind == "poem" && "notebook-poem"}>
      <h3 :if={@section.title} class="notebook-section-title mb-1">
        {section_icon(@section.kind)} {@section.title}
      </h3>
      <div class="prose prose-sm max-w-none">
        {raw_markdown(@section.body)}
      </div>
      <a
        :if={@section.metadata["source_url"]}
        href={@section.metadata["source_url"]}
        target="_blank"
        rel="noopener noreferrer nofollow"
        class="link text-sm"
      >
        {@section.metadata["source_label"] || @section.metadata["source_url"]} ↗
      </a>
    </div>
    """
  end

  defp raw_markdown(nil), do: ""

  defp raw_markdown(text) do
    case MDEx.to_html(text) do
      {:ok, html} -> Phoenix.HTML.raw(html)
      _ -> text
    end
  end

  defp section_icon("poem"), do: "✒️"
  defp section_icon("description"), do: "🗺️"
  defp section_icon("art_culture"), do: "🎭"
  defp section_icon("products"), do: "🧺"
  defp section_icon("kindness"), do: "💛"
  defp section_icon(_), do: ""

  defp reaction_kinds do
    [{"love", "❤️"}, {"inspiring", "✨"}, {"want_more", "➕"}, {"not_for_me", "🤷"}]
  end

  defp map_points(path_points, poet) do
    points =
      Enum.map(path_points, fn p ->
        %{lat: p.lat, lng: p.lng, name: p.place_name}
      end)

    current =
      if poet.current_lat do
        %{lat: poet.current_lat, lng: poet.current_lng, name: poet.current_place_name}
      end

    %{path: points, current: current, poet: poet.name}
  end

  defp entry_nav(entries, current) do
    dates = Enum.map(entries, & &1.entry_date) |> Enum.sort(Date)
    idx = Enum.find_index(dates, &(&1 == current.entry_date))

    # ISO strings, not Date structs — Date has no Phoenix.Param impl, and a
    # bare struct in ~p"/journal/#{date}" crashes the render (only once a poet
    # has 2+ entries, which is why day one didn't catch it)
    prev =
      if idx && idx > 0, do: [{"← earlier", Date.to_iso8601(Enum.at(dates, idx - 1))}], else: []

    next =
      if idx && idx < length(dates) - 1,
        do: [{"later →", Date.to_iso8601(Enum.at(dates, idx + 1))}],
        else: []

    prev ++ next
  end

  ## Chat helpers (ported from alice-in DashboardLive)

  defp keepalive_after_agent_turn(%{sprite_name: name}) when is_binary(name) and name != "" do
    Task.start(fn -> SpritesClient.exec(name, hold_awake_cmd(90)) end)
    :ok
  end

  defp keepalive_after_agent_turn(_), do: :ok

  defp mark_activity(socket) do
    assign(socket, :last_activity_at, System.monotonic_time(:millisecond))
  end

  # The gateway rejects a chat.send while another turn is running (e.g. the
  # auto-fired /onboard right after provisioning) with a bare "Chat error" —
  # translate it into something a user can act on.
  defp friendly_error(reason, socket) when is_binary(reason) do
    poet_name = (socket.assigns[:poet] && socket.assigns.poet.name) || "Your poet"

    if String.contains?(reason, "Chat error") do
      "#{poet_name} is mid-thought (possibly writing to you right now) — give it a moment and resend."
    else
      reason
    end
  end

  defp friendly_error(reason, _socket), do: reason

  defp recently_active?(socket) do
    case socket.assigns[:last_activity_at] do
      nil -> false
      t -> System.monotonic_time(:millisecond) - t < @keepalive_active_window_ms
    end
  end

  # A held-open exec is what keeps a sprite "running" — a quick ping doesn't.
  defp hold_awake_cmd(seconds) do
    "for i in $(seq 1 #{seconds}); do sleep 1; done"
  end

  # Fires /onboard exactly once per user on first gateway :connected — agents
  # don't initiate chat on their own. Idempotency via users.agent_onboarded_at.
  defp maybe_fire_agent_onboard(socket) do
    user = socket.assigns.user
    pid = socket.assigns.gateway_socket_pid

    cond do
      user.agent_onboarded_at != nil ->
        socket

      is_nil(pid) ->
        socket

      true ->
        GatewaySocket.send_message(pid, "/onboard")

        case Accounts.update_user(user, %{agent_onboarded_at: DateTime.utc_now()}) do
          {:ok, updated} ->
            Logger.info("Auto-fired /onboard for user #{user.id}")
            assign(socket, :user, updated)

          {:error, reason} ->
            Logger.error("Failed to mark user #{user.id} agent_onboarded: #{inspect(reason)}")
            socket
        end
    end
  end

  defp dispatch_to_gateway(socket, message) do
    user = socket.assigns.user
    socket = ensure_gateway_connected(socket)
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
