defmodule TravelingPoetWeb.JournalLive do
  use TravelingPoetWeb, :live_view

  alias TravelingPoet.{
    Accounts,
    Chat,
    Credits,
    FirstEntry,
    GatewaySocket,
    GatewaySocketSupervisor,
    Journal,
    Poets
  }

  alias TravelingPoet.{Preferences, SpriteUploads, SpritesClient, Usage}
  alias TravelingPoet.Journal.Media
  alias TravelingPoetWeb.ChatSidebarComponent

  require Logger

  @keepalive_interval_ms 20_000
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
          |> assign(:sidebar_open, true)
          |> assign(:keepalive_ref, nil)
          |> assign(:last_activity_at, nil)
          |> assign(:sprite_status, initial_sprite_status)
          |> assign(:show_anyway, false)
          |> assign(:mobile_chat_open, false)
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

        {:noreply, socket |> assign_journal(poet, date) |> push_map()}
    end
  end

  # The map div is phx-update="ignore" (Leaflet owns its DOM), so a changed
  # data-points attribute does NOT re-render it. Paging between entries has to
  # tell the hook directly or the map silently keeps the previous day's view.
  defp push_map(socket) do
    if connected?(socket) do
      push_event(
        socket,
        "map:update",
        map_points(socket.assigns.path_points, socket.assigns.poet, socket.assigns.entry)
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

    media_map = entry_media_map(poet, entry)
    entry = record_view(socket, poet, entry)

    socket
    |> assign(:entries, entries)
    |> assign(:entry, entry)
    |> assign(:entry_media, media_map)
    |> assign(:extra_media, extra_media(entry))
    |> assign(:my_reactions, my_reactions(entry, socket.assigns.current_user))
    |> assign(:path_points, Poets.list_path_points(poet.id))
    |> assign_prompt(poet, entry)
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

  defp extra_media(nil), do: []
  defp extra_media(entry), do: Journal.unattached_illustrations(entry, entry.sections)

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
  def handle_event("peek_anyway", _params, socket) do
    {:noreply, assign(socket, :show_anyway, true)}
  end

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
  def handle_info({:credits_updated, _balance}, socket) do
    user = Accounts.get_user!(socket.assigns.user.id)

    {:noreply,
     socket
     |> assign(:user, user)
     |> assign(:current_user, user)
     |> assign(:credits_low, Credits.low?(user, socket.assigns.poet))}
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
  def handle_info(:setup_refresh, socket) do
    if setting_up?(socket.assigns) do
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

      {:noreply,
       socket
       |> assign(:user, user)
       |> assign(:poet, poet)
       |> assign(:sprite_status, sprite_status)
       |> assign_journal(poet, nil)}
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

  # New poets show a setting-up screen until their first entry publishes
  # (entry #0 from the bootstrap ritual) — the point at which everything is
  # truly operational. Beta feedback: landing straight in the half-alive
  # journal + chat during provisioning was confusing. The gateway wiring
  # keeps running underneath so /onboard still auto-fires.
  defp setting_up?(assigns) do
    assigns.entries == [] and not assigns.show_anyway
  end

  # Whole minutes since the poet was created. The setup screen re-renders every
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

  attr :poet, :any, required: true
  attr :user, :any, required: true
  attr :sprite_status, :atom, required: true

  defp setting_up_screen(assigns) do
    ~H"""
    <div class="mx-auto max-w-md py-16 text-center">
      <div class="text-6xl animate-bounce mb-6">🧳</div>
      <h1 class="text-2xl font-semibold mb-2">{@poet.name} is getting ready</h1>
      <p class="opacity-70 mb-8">
        Packing a notebook, lacing boots, finding the first light in {@poet.current_place_name ||
          "the starting place"}…
      </p>

      <ol class="text-left space-y-3 mb-8">
        <li class="flex items-center gap-3">
          <.step_mark done={@sprite_status in [:provisioned, :running, :waking, :reconnecting]} />
          <span>Setting up {@poet.name}'s travel desk</span>
        </li>
        <li class="flex items-center gap-3">
          <.step_mark done={@user.agent_onboarded_at != nil} />
          <span>Waking the poet</span>
        </li>
        <li class="flex items-center gap-3">
          <.step_mark done={false} />
          <span>Writing the first journal entry</span>
        </li>
      </ol>

      <p class="text-sm opacity-60 mb-2">
        <span :if={setup_minutes(@poet) < 20}>
          Setting up takes a few minutes; the first journal entry usually follows
          within <b>20</b>.
        </span>
        <span :if={setup_minutes(@poet) >= 20}>
          This one is taking longer than usual — nothing is lost, and the poet is
          still working.
        </span>
        <span :if={setup_minutes(@poet) >= 1}>
          Yours has been getting ready for <b>{setup_minutes(@poet)} minutes</b>.
        </span>
        The page updates by itself — and you can safely close it; the poet keeps working.
      </p>
      <p :if={@user.telegram_chat_id} class="text-sm opacity-60 mb-6">
        📱 We'll message you on Telegram the moment the first entry is out.
      </p>
      <p :if={is_nil(@user.telegram_chat_id)} class="text-sm opacity-60 mb-6">
        Tip: pair Telegram in <.link navigate={~p"/settings"} class="link">settings</.link>
        and your poet will write to you there when it's ready.
      </p>

      <button phx-click="peek_anyway" class="btn btn-ghost btn-xs opacity-60">
        peek behind the curtain anyway
      </button>
    </div>
    """
  end

  attr :done, :boolean, required: true

  defp step_mark(assigns) do
    ~H"""
    <span :if={@done} class="text-success text-lg">✓</span>
    <span :if={!@done} class="loading loading-dots loading-sm opacity-50"></span>
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
    >
      <.setting_up_screen
        :if={setting_up?(assigns)}
        poet={@poet}
        user={@user}
        sprite_status={@sprite_status}
      />
      <div :if={!setting_up?(assigns)} class="flex h-[calc(100vh-4rem)] gap-4">
        <div class="flex-1 min-w-0 overflow-y-auto pr-1">
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
                  · preparing to set out…
                </span>
              </p>
            </div>
            <button
              phx-click="toggle_chat"
              class="ml-auto hidden lg:inline-flex btn btn-ghost btn-sm"
              aria-label="Toggle chat"
            >
              💬 {if @sidebar_open, do: "Hide chat", else: "Chat"}
            </button>
          </div>

          <div
            id="poet-map"
            phx-hook="PoetMap"
            phx-update="ignore"
            class="w-full h-64 rounded-xl border border-base-300 z-0"
            data-points={Jason.encode!(map_points(@path_points, @poet, @entry))}
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

            <div :for={media <- @extra_media} class="mb-6">
              <.section section={%{kind: "illustration"}} media={media} />
            </div>

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
          mobile_chat_open={@mobile_chat_open}
          chat_attachment_upload={@uploads.chat_attachment}
        />

        <button
          :if={!@mobile_chat_open}
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

  # `entry` focuses the map on the day you are actually reading. Without it the
  # map only ever knew the poet's path and where it is NOW, so paging back
  # through the journal left it sitting on the current city while the page
  # talked about somewhere else entirely.
  defp map_points(path_points, poet, entry) do
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
      focus: focus_point(entry)
    }
  end

  defp focus_point(%{lat: lat, lng: lng} = entry) when is_number(lat) and is_number(lng) do
    %{lat: lat, lng: lng, name: entry.place_name, date: Date.to_iso8601(entry.entry_date)}
  end

  defp focus_point(_), do: nil

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
