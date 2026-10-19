defmodule TravelingPoetWeb.ChatSidebarComponent do
  use TravelingPoetWeb, :live_component

  alias TravelingPoet.Chat

  require Logger

  @control_tags ~w(think final)
  @control_tag_pattern ~r/<\/?(?:#{Enum.join(@control_tags, "|")})>/i

  def display_content(%{role: "user", content: content}), do: content || ""
  def display_content(%{content: content}), do: strip_control_tags(content)

  def strip_control_tags(nil), do: ""

  def strip_control_tags(text) when is_binary(text) do
    @control_tag_pattern
    |> Regex.replace(text, "")
    |> String.trim_leading()
  end

  # Agent text: strip control tags, then render markdown to sanitized HTML.
  # Returns a Phoenix.HTML safe tuple so HEEx renders it without re-escaping.
  # The defensive case keeps a pathological LLM string from crashing the component.
  def render_markdown(content) do
    stripped = strip_control_tags(content)

    case MDEx.to_html(stripped,
           extension: [table: true, strikethrough: true, autolink: true, tasklist: true],
           render: [escape: false],
           syntax_highlight: nil,
           sanitize: MDEx.Document.default_sanitize_options()
         ) do
      {:ok, html} -> Phoenix.HTML.raw(html)
      {:error, _} -> Phoenix.HTML.html_escape(stripped)
    end
  end

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:messages, [])
     |> assign(:input, "")
     |> assign(:streaming, false)
     |> assign(:current_response, "")
     |> assign(:error, nil)
     |> assign(:mobile_chat_open, false)
     |> assign(:external_turn, false)
     |> assign(:held, false)
     |> assign(:first_entry, nil)
     |> assign(:sprite_status, :unknown)}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, :id, assigns.id)

    socket =
      if assigns[:user],
        do: assign(socket, :user, assigns.user),
        else: socket

    socket =
      if Map.has_key?(assigns, :poet_name),
        do: assign(socket, :poet_name, assigns.poet_name),
        else: assign_new(socket, :poet_name, fn -> nil end)

    socket =
      if assigns[:sidebar_open] != nil,
        do: assign(socket, :sidebar_open, assigns.sidebar_open),
        else: socket

    socket =
      if assigns[:mobile_chat_open] != nil,
        do: assign(socket, :mobile_chat_open, assigns.mobile_chat_open),
        else: socket

    socket =
      if assigns[:chat_attachment_upload],
        do: assign(socket, :chat_attachment_upload, assigns.chat_attachment_upload),
        else: socket

    socket =
      if Map.has_key?(assigns, :first_entry),
        do: assign(socket, :first_entry, assigns.first_entry),
        else: socket

    # Load messages from DB on first render
    socket =
      if socket.assigns[:messages_loaded] do
        socket
      else
        user = socket.assigns.user

        messages = Chat.list_messages(user.id)

        socket
        |> assign(:messages, messages)
        |> assign(:messages_loaded, true)
        |> assign_sprite_status(user)
      end

    # Handle forwarded events from DashboardLive
    socket = handle_forwarded_event(assigns, socket)

    {:ok, socket}
  end

  defp assign_sprite_status(socket, user) do
    status =
      cond do
        user.sprite_provisioned && user.sprite_url -> :running
        user.sprite_provisioned -> :provisioned
        true -> :not_provisioned
      end

    assign(socket, :sprite_status, status)
  end

  # Text arriving with no send of ours in flight is a turn the app started
  # (the first-entry ritual, a daily run the reader happens to be watching).
  # Show it as it streams rather than dropping it on the floor until :done.
  defp handle_forwarded_event(%{stream_delta: delta}, socket) do
    socket = if socket.assigns.streaming, do: socket, else: begin_external_turn(socket)
    assign(socket, :current_response, socket.assigns.current_response <> delta)
  end

  defp handle_forwarded_event(%{stream_replace: text}, socket) do
    socket = if socket.assigns.streaming, do: socket, else: begin_external_turn(socket)
    assign(socket, :current_response, text)
  end

  defp handle_forwarded_event(%{stream_done: response_id}, socket) do
    content = socket.assigns.current_response
    user = socket.assigns.user

    # Save the agent message unless it is empty (tool-only turn) or
    # AgentSession already saved this same reply for a turn it drove.
    socket =
      with true <- content != "",
           {:ok, %Chat.ChatMessage{} = msg} <-
             Chat.create_agent_message_once(%{
               user_id: user.id,
               content: content,
               response_id: response_id
             }) do
        assign(socket, :messages, socket.assigns.messages ++ [msg])
      else
        _ -> socket
      end

    socket
    |> assign(:streaming, false)
    |> assign(:external_turn, false)
    |> assign(:held, false)
    |> assign(:current_response, "")
    |> assign(:error, nil)
  end

  defp handle_forwarded_event(%{stream_error: reason}, socket) do
    assign(socket,
      streaming: false,
      external_turn: false,
      held: false,
      error: dgettext("journal", "Agent error: %{reason}", reason: reason)
    )
  end

  # The gateway turned our message away because another turn was running;
  # the parent keeps the text and resends it when that turn ends.
  defp handle_forwarded_event(%{stream_held: true}, socket) do
    assign(socket, streaming: true, held: true, error: nil)
  end

  defp handle_forwarded_event(%{stream_resent: true}, socket) do
    assign(socket, streaming: true, external_turn: false, held: false, current_response: "")
  end

  defp handle_forwarded_event(%{sprite_waking: true}, socket) do
    assign(socket, sprite_status: :waking)
  end

  defp handle_forwarded_event(%{sprite_waking: false}, socket) do
    assign(socket, sprite_status: :running)
  end

  defp handle_forwarded_event(%{connection_status: :reconnecting}, socket) do
    assign(socket, sprite_status: :reconnecting)
  end

  defp handle_forwarded_event(%{connection_status: :connected}, socket) do
    assign(socket, sprite_status: :running)
  end

  defp handle_forwarded_event(%{sprite_provisioned: _result}, socket) do
    user = TravelingPoet.Accounts.get_user!(socket.assigns.user.id)

    socket
    |> assign(:user, user)
    |> assign_sprite_status(user)
  end

  defp handle_forwarded_event(%{append_user_message: msg}, socket) do
    socket
    |> assign(:messages, socket.assigns.messages ++ [msg])
    |> begin_own_turn()
  end

  defp handle_forwarded_event(%{append_agent_message: msg}, socket) do
    if Enum.any?(socket.assigns.messages, &(&1.id == msg.id)),
      do: socket,
      else: assign(socket, :messages, socket.assigns.messages ++ [msg])
  end

  defp handle_forwarded_event(_assigns, socket), do: socket

  defp begin_external_turn(socket) do
    assign(socket, streaming: true, external_turn: true, error: nil, current_response: "")
  end

  # Sending during a turn the app started must not wipe the narration bubble
  # mid-sentence; the reply to our message comes after that turn anyway.
  defp begin_own_turn(socket) do
    socket
    |> assign(:input, "")
    |> assign(:streaming, true)
    |> assign(:error, nil)
    |> then(fn s ->
      if s.assigns.external_turn, do: s, else: assign(s, :current_response, "")
    end)
  end

  @impl true
  def handle_event("update_input", %{"message" => value}, socket) do
    {:noreply, assign(socket, input: value)}
  end

  @impl true
  def handle_event("send", params, socket) do
    message = params |> Map.get("message", "") |> String.trim()
    has_attachment? = attachment_pending?(socket)

    cond do
      has_attachment? ->
        # Parent owns the upload + persistence + send when an attachment is present.
        send(self(), {:chat_send, message, true})
        {:noreply, begin_own_turn(socket)}

      message != "" ->
        user = socket.assigns.user

        {:ok, msg} =
          Chat.create_message(%{
            user_id: user.id,
            role: "user",
            content: message
          })

        send(self(), {:chat_send, message, false})

        {:noreply,
         socket
         |> assign(:messages, socket.assigns.messages ++ [msg])
         |> begin_own_turn()}

      true ->
        {:noreply, socket}
    end
  end

  defp attachment_pending?(socket) do
    case socket.assigns[:chat_attachment_upload] do
      %{entries: [_ | _]} -> true
      _ -> false
    end
  end

  @doc """
  The chat as the notebook's own notepad (card-69): a sheet of the same
  paper, the poet's name in its hand, the poet's lines in the journal's
  writing and the reader's in the app's type on a tint of the paper, no
  bubbles, no badges, an ink ring to send. Readers found the stock white
  panel with blue bubbles "unrelated" to the app; the classes below are
  styled in app.css under .chat-pad, the layout classes stay Tailwind.
  """
  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="chat-sidebar-panel"
      phx-hook="MobileViewport"
      class={
        [
          "chat-pad flex-col",
          # phone: hidden until opened, then a fullscreen overlay.
          # tablet (md): the same overlay narrowed to a drawer on the right,
          # so the notebook keeps the whole width underneath it.
          if(@mobile_chat_open,
            do:
              "chat-overlay flex fixed inset-0 z-50 md:start-auto md:w-[min(24rem,100vw)] md:shadow-2xl",
            else: "hidden"
          ),
          # wide desk (xl): static side panel, width from --chat-width. Only
          # there is there room for two pages AND a chat column.
          "xl:static xl:inset-auto xl:z-auto xl:shadow-none",
          if(@sidebar_open,
            do: "xl:flex xl:w-[var(--chat-width,24rem)]",
            else: "xl:hidden"
          )
        ]
      }
    >
      <div :if={@sidebar_open or @mobile_chat_open} class="flex flex-col h-full">
        <div class="chat-pad-head flex items-center justify-between gap-2 px-4 pt-3 pb-2">
          <div class="min-w-0">
            <h3 class="chat-pad-name truncate">{poet_name(assigns)}</h3>
            <span class="chat-pad-status" data-status={@sprite_status}>
              {status_label(@sprite_status)}
            </span>
          </div>
          <button
            phx-click="toggle_mobile_chat"
            class="xl:hidden chat-pad-close"
            aria-label={dgettext("journal", "Close chat")}
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <%= if @sprite_status in [:not_provisioned, :unknown] do %>
          <div class="flex-1 flex items-center justify-center p-6">
            <div class="chat-pad-empty text-center">
              <p class="chat-pad-empty-title">
                {dgettext("journal", "%{poet} is still being set up.", poet: poet_name(assigns))}
              </p>
              <p>{dgettext("journal", "The notepad opens the moment they are reachable.")}</p>
            </div>
          </div>
        <% else %>
          <div
            id="chat-messages"
            class="flex-1 overflow-y-auto px-4 py-3 space-y-4"
            phx-hook="ScrollBottom"
          >
            <%= if @messages == [] and !@streaming do %>
              <div class="chat-pad-empty text-center mt-10">
                <p class="chat-pad-empty-title">
                  {dgettext("journal", "Write to %{poet}.", poet: poet_name(assigns))}
                </p>
                <p>
                  {dgettext("journal", "Ask for a place, a detour, a drawing. Or just say hello.")}
                </p>
              </div>
            <% end %>

            <%= for msg <- @messages do %>
              <div class={["chat-line", msg.role == "user" && "chat-line-reader"]}>
                <%= if msg.role == "user" do %>
                  <span class="chat-pad-who chat-pad-who-reader">{reader_name(assigns)}</span>
                  <div class="chat-reader whitespace-pre-wrap" dir="auto">{display_content(msg)}</div>
                <% else %>
                  <span class="chat-pad-who">{poet_name(assigns)}</span>
                  <div class="chat-markdown chat-poet" dir="auto">{render_markdown(msg.content)}</div>
                <% end %>
                <%= for file <- attachment_files(msg) do %>
                  <div class="chat-pad-chip">
                    <.icon name="hero-paper-clip" class="size-3.5" />
                    <span class="font-medium">{file["filename"]}</span>
                    <span class="opacity-60">{format_size(file["size"])}</span>
                  </div>
                <% end %>
              </div>
            <% end %>

            <%= if @streaming do %>
              <div class="chat-line">
                <span class="chat-pad-who">{poet_name(assigns)}</span>
                <div class="chat-markdown chat-poet" dir="auto">
                  {render_markdown(@current_response)}<span class="chat-pad-cursor" aria-hidden="true"></span>
                </div>
              </div>
            <% end %>

            <%= if @held do %>
              <p id="chat-held-note" class="chat-pad-note">
                {dgettext(
                  "journal",
                  "Held until %{poet} finishes the page. It goes out on its own.",
                  poet: poet_name(assigns)
                )}
              </p>
            <% end %>

            <%= if @error do %>
              <p class="chat-pad-note chat-pad-note-error" role="alert">{@error}</p>
            <% end %>
          </div>

          <div class="chat-pad-composer px-4 pt-2 pb-3" phx-drop-target={attachment_ref(assigns)}>
            <p
              :if={@first_entry == :in_flight and not @held}
              id="chat-first-entry-hint"
              class="chat-pad-note mb-2"
            >
              {dgettext(
                "journal",
                "%{poet} is writing the first entry. A message sent now waits until the page is done.",
                poet: poet_name(assigns)
              )}
            </p>
            <%= for entry <- attachment_entries(assigns) do %>
              <div class="chat-pad-chip chat-pad-chip-pending mb-2">
                <.icon name="hero-paper-clip" class="size-3.5" />
                <span class="flex-1 truncate font-medium">{entry.client_name}</span>
                <span class="opacity-60">{format_size(entry.client_size)}</span>
                <%= if entry.progress > 0 and entry.progress < 100 do %>
                  <span>{entry.progress}%</span>
                <% end %>
                <button
                  type="button"
                  phx-click="cancel_attachment"
                  phx-value-ref={entry.ref}
                  aria-label={dgettext("journal", "Remove attachment")}
                  class="chat-pad-chip-remove"
                >
                  <.icon name="hero-x-mark" class="size-4" />
                </button>
              </div>
            <% end %>
            <%= for err <- attachment_errors(assigns) do %>
              <p class="chat-pad-note chat-pad-note-error mb-2">{upload_error_message(err)}</p>
            <% end %>

            <form
              :if={@chat_attachment_upload}
              id="chat-attachment-form"
              phx-change="validate_attachment"
              phx-submit={nil}
              class="hidden"
            >
              <.live_file_input upload={@chat_attachment_upload} />
            </form>

            <form phx-submit="send" phx-change="update_input" phx-target={@myself}>
              <div class="flex gap-2 items-end">
                <label
                  :if={@chat_attachment_upload}
                  for={@chat_attachment_upload.ref}
                  title={dgettext("journal", "Attach a file")}
                  class={["chat-pad-attach", @streaming && "opacity-50 cursor-not-allowed"]}
                >
                  <.icon name="hero-paper-clip" class="size-5" />
                  <span class="sr-only">{dgettext("journal", "Attach a file")}</span>
                </label>
                <textarea
                  name="message"
                  placeholder={dgettext("journal", "Write to %{poet}…", poet: poet_name(assigns))}
                  disabled={composer_locked?(assigns)}
                  rows="1"
                  dir="auto"
                  class="chat-pad-input flex-1 resize-none overflow-y-auto max-h-40"
                  autocomplete="off"
                  phx-hook="ChatInput"
                  id="chat-input"
                ></textarea>
                <button
                  type="submit"
                  disabled={composer_locked?(assigns) or attachment_uploading?(assigns)}
                  class="chat-pad-send"
                  aria-label={send_label(assigns)}
                  title={send_label(assigns)}
                >
                  <.icon name={send_icon(assigns)} class={send_icon_class(assigns)} />
                </button>
              </div>
            </form>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # -- helpers --

  # Our own turn locks the composer until the reply lands, and so does a held
  # message (one at a time). A turn the app started does not: the reader may
  # still say hello, and the parent holds it if the gateway is busy.
  defp composer_locked?(%{streaming: true, held: true}), do: true
  defp composer_locked?(%{streaming: true, external_turn: false}), do: true
  defp composer_locked?(_), do: false

  defp send_label(%{held: true}), do: dgettext("journal", "Held")
  defp send_label(%{streaming: true, external_turn: false}), do: dgettext("journal", "Sending")
  defp send_label(_), do: dgettext("journal", "Send")

  defp send_icon(%{held: true}), do: "hero-clock"
  defp send_icon(%{streaming: true, external_turn: false}), do: "hero-arrow-path"
  defp send_icon(_), do: "hero-paper-airplane"

  defp send_icon_class(%{streaming: true, external_turn: false, held: false}),
    do: "size-4 motion-safe:animate-spin"

  defp send_icon_class(_), do: "size-4"

  # The poet's name as the reader gave it (the journal passes it); the
  # sprite's `users.agent_name` mirrors it and stands in when it is missing.
  defp poet_name(%{poet_name: name}) when is_binary(name) and name != "", do: name
  defp poet_name(%{user: %{agent_name: name}}) when is_binary(name) and name != "", do: name
  defp poet_name(_assigns), do: dgettext("journal", "Your poet")

  # The reader's own lines carry their first name, in the same hand as the
  # poet's, so a lone highlighted line still says whose it is (Udi, 2026-10-16:
  # the tint alone did not).
  defp reader_name(%{user: %{name: name}}) when is_binary(name) do
    case name |> String.trim() |> String.split(~r/\s+/, parts: 2) do
      [first | _] when first != "" -> first
      _ -> dgettext("journal", "You")
    end
  end

  defp reader_name(_assigns), do: dgettext("journal", "You")

  # Plain words in the paper's ink, never a coloured badge.
  defp status_label(:running), do: dgettext("journal", "awake")
  defp status_label(:waking), do: dgettext("journal", "waking up…")
  defp status_label(:reconnecting), do: dgettext("journal", "reconnecting…")
  defp status_label(:provisioned), do: dgettext("journal", "ready")
  defp status_label(:not_provisioned), do: dgettext("journal", "setting up")
  defp status_label(:unknown), do: dgettext("journal", "checking…")

  defp attachment_ref(%{chat_attachment_upload: %{ref: ref}}), do: ref
  defp attachment_ref(_), do: nil

  defp attachment_entries(%{chat_attachment_upload: %{entries: entries}}), do: entries
  defp attachment_entries(_), do: []

  defp attachment_errors(%{chat_attachment_upload: upload}) when not is_nil(upload) do
    Phoenix.Component.upload_errors(upload) ++
      Enum.flat_map(upload.entries, fn entry ->
        Enum.map(Phoenix.Component.upload_errors(upload, entry), fn err -> {entry, err} end)
      end)
  end

  defp attachment_errors(_), do: []

  defp attachment_uploading?(assigns) do
    Enum.any?(attachment_entries(assigns), fn e -> not e.done? end)
  end

  defp upload_error_message({_entry, :too_large}),
    do: dgettext("journal", "File is too large (max 25 MB).")

  defp upload_error_message({_entry, :not_accepted}),
    do: dgettext("journal", "File type is not accepted.")

  defp upload_error_message({_entry, err}),
    do: dgettext("journal", "Upload error: %{error}", error: inspect(err))

  defp upload_error_message(:too_many_files),
    do: dgettext("journal", "Only one attachment per message.")

  defp upload_error_message(err),
    do: dgettext("journal", "Upload error: %{error}", error: inspect(err))

  defp attachment_files(%{attachments: %{"files" => files}}) when is_list(files), do: files
  defp attachment_files(_), do: []

  defp format_size(nil), do: ""
  defp format_size(bytes) when is_integer(bytes) and bytes < 1024, do: "#{bytes} B"

  defp format_size(bytes) when is_integer(bytes) and bytes < 1024 * 1024,
    do: "#{Float.round(bytes / 1024, 1)} KB"

  defp format_size(bytes) when is_integer(bytes),
    do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"
end
