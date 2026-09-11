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
    # AgentSession already persisted this same reply for a turn it drove.
    socket =
      if content != "" and not Chat.recent_agent_message_exists?(user.id, content) do
        {:ok, msg} =
          Chat.create_message(%{
            user_id: user.id,
            role: "agent",
            content: content,
            response_id: response_id
          })

        assign(socket, :messages, socket.assigns.messages ++ [msg])
      else
        socket
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
      error: "Agent error: #{reason}"
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

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="chat-sidebar-panel"
      phx-hook="MobileViewport"
      class={
        [
          "flex-col bg-white border-slate-200",
          # mobile: hidden until the floating button opens it as a fullscreen overlay
          if(@mobile_chat_open,
            do:
              "flex fixed inset-0 z-50 pt-[env(safe-area-inset-top)] pb-[env(safe-area-inset-bottom)] lg:pt-0 lg:pb-0",
            else: "hidden"
          ),
          # desktop: static side panel, width from the resizer's --chat-width
          "lg:static lg:inset-auto lg:z-auto lg:border-l",
          if(@sidebar_open,
            do: "lg:flex lg:w-[var(--chat-width,24rem)]",
            else: "lg:hidden"
          )
        ]
      }
    >
      <div :if={@sidebar_open or @mobile_chat_open} class="flex flex-col h-full">
        <!-- Header -->
        <div class="flex items-center justify-between px-4 py-3 border-b border-slate-200 bg-slate-50">
          <div>
            <h3 class="font-semibold text-slate-900 text-sm">
              {if @user.agent_name && @user.agent_name != "", do: @user.agent_name, else: "AI Agent"}
            </h3>
            <span class={"text-xs px-2 py-0.5 rounded-full #{status_class(@sprite_status)}"}>
              {status_label(@sprite_status)}
            </span>
          </div>
          <button
            phx-click="toggle_mobile_chat"
            class="lg:hidden btn btn-ghost btn-sm text-lg"
            aria-label="Close chat"
          >
            ✕
          </button>
        </div>

        <%= if @sprite_status in [:not_provisioned, :unknown] do %>
          <!-- Not provisioned message -->
          <div class="flex-1 flex items-center justify-center p-4">
            <div class="text-center text-slate-500 text-sm">
              <p class="mb-2">Your poet is still being set up.</p>
              <p>The chat opens the moment it is reachable.</p>
            </div>
          </div>
        <% else %>
          <!-- Messages -->
          <div
            id="chat-messages"
            class="flex-1 overflow-y-auto p-4 space-y-3"
            phx-hook="ScrollBottom"
          >
            <%= if @messages == [] and !@streaming do %>
              <div class="text-center text-slate-400 mt-8">
                <p class="text-sm">Send a message to start chatting</p>
              </div>
            <% end %>

            <%= for msg <- @messages do %>
              <div class={"flex #{if msg.role == "user", do: "justify-end", else: "justify-start"}"}>
                <div class={"max-w-[85%] rounded-lg px-3 py-2 text-sm #{msg_class(msg.role)}"}>
                  <div class="text-xs text-slate-400 mb-1">
                    {if msg.role == "user", do: "You", else: @user.agent_name || "Agent"}
                  </div>
                  <%= if msg.role == "user" do %>
                    <div class="whitespace-pre-wrap">{display_content(msg)}</div>
                  <% else %>
                    <div class="chat-markdown">{render_markdown(msg.content)}</div>
                  <% end %>
                  <%= for file <- attachment_files(msg) do %>
                    <div class="mt-2 inline-flex items-center gap-2 px-2 py-1 rounded bg-white/60 border border-slate-200 text-xs text-slate-700">
                      <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          stroke-width="2"
                          d="M15.172 7l-6.586 6.586a2 2 0 102.828 2.828l6.414-6.586a4 4 0 00-5.656-5.656L5.05 11.293a6 6 0 108.485 8.485L20 13.314"
                        />
                      </svg>
                      <span class="font-medium">{file["filename"]}</span>
                      <span class="text-slate-400">{format_size(file["size"])}</span>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>

            <%= if @streaming do %>
              <div class="flex justify-start">
                <div class="max-w-[85%] rounded-lg px-3 py-2 text-sm bg-slate-100 text-slate-800">
                  <div class="text-xs text-slate-400 mb-1">{@user.agent_name || "Agent"}</div>
                  <div class="chat-markdown">
                    {render_markdown(@current_response)}<span class="animate-pulse">|</span>
                  </div>
                </div>
              </div>
            <% end %>

            <%= if @held do %>
              <div
                id="chat-held-note"
                class="bg-amber-50 border border-amber-200 rounded-lg px-3 py-2 text-amber-800 text-xs"
              >
                Held until {@user.agent_name || "your poet"} finishes the page. It goes out on its own.
              </div>
            <% end %>

            <%= if @error do %>
              <div class="bg-red-50 border border-red-200 rounded-lg px-3 py-2 text-red-600 text-xs">
                {@error}
              </div>
            <% end %>
          </div>

          <!-- Input -->
          <div class="border-t border-slate-200 p-3" phx-drop-target={attachment_ref(assigns)}>
            <p
              :if={@first_entry == :in_flight and not @held}
              id="chat-first-entry-hint"
              class="mb-2 text-xs text-slate-500"
            >
              {@user.agent_name || "Your poet"} is writing the first entry. A message sent now waits
              until the page is done.
            </p>
            <%= for entry <- attachment_entries(assigns) do %>
              <div class="mb-2 flex items-center gap-2 px-2 py-1.5 rounded-lg bg-slate-100 border border-slate-200 text-xs">
                <svg
                  class="w-4 h-4 text-slate-500"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M15.172 7l-6.586 6.586a2 2 0 102.828 2.828l6.414-6.586a4 4 0 00-5.656-5.656L5.05 11.293a6 6 0 108.485 8.485L20 13.314"
                  />
                </svg>
                <span class="flex-1 truncate text-slate-700 font-medium">{entry.client_name}</span>
                <span class="text-slate-400">{format_size(entry.client_size)}</span>
                <%= if entry.progress > 0 and entry.progress < 100 do %>
                  <span class="text-blue-600">{entry.progress}%</span>
                <% end %>
                <button
                  type="button"
                  phx-click="cancel_attachment"
                  phx-value-ref={entry.ref}
                  aria-label="Remove attachment"
                  class="p-0.5 text-slate-400 hover:text-slate-700"
                >
                  <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M6 18L18 6M6 6l12 12"
                    />
                  </svg>
                </button>
              </div>
            <% end %>
            <%= for err <- attachment_errors(assigns) do %>
              <div class="mb-2 text-xs text-red-600">
                {upload_error_message(err)}
              </div>
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
                  title="Attach a file"
                  class={[
                    "shrink-0 cursor-pointer p-2 text-slate-500 hover:text-slate-700 hover:bg-slate-100 rounded-lg transition-colors",
                    @streaming && "opacity-50 cursor-not-allowed"
                  ]}
                >
                  <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M15.172 7l-6.586 6.586a2 2 0 102.828 2.828l6.414-6.586a4 4 0 00-5.656-5.656L5.05 11.293a6 6 0 108.485 8.485L20 13.314"
                    />
                  </svg>
                </label>
                <textarea
                  name="message"
                  placeholder="Type a message..."
                  disabled={composer_locked?(assigns)}
                  rows="1"
                  class="flex-1 px-3 py-2 text-sm text-slate-900 bg-white rounded-lg border border-slate-300 focus:border-blue-500 focus:ring-1 focus:ring-blue-200 focus:outline-none disabled:opacity-50 resize-none overflow-y-auto max-h-40 leading-5"
                  autocomplete="off"
                  phx-hook="ChatInput"
                  id="chat-input"
                ></textarea>
                <button
                  type="submit"
                  disabled={composer_locked?(assigns) or attachment_uploading?(assigns)}
                  class="px-4 py-2 text-sm bg-blue-600 hover:bg-blue-500 disabled:bg-slate-300 text-white rounded-lg font-medium transition-colors"
                >
                  {send_label(assigns)}
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

  defp send_label(%{held: true}), do: "Held"
  defp send_label(%{streaming: true, external_turn: false}), do: "..."
  defp send_label(_), do: "Send"

  defp status_class(:running), do: "bg-green-100 text-green-700"
  defp status_class(:waking), do: "bg-yellow-100 text-yellow-700"
  defp status_class(:reconnecting), do: "bg-yellow-100 text-yellow-700"
  defp status_class(:provisioned), do: "bg-blue-100 text-blue-700"
  defp status_class(:not_provisioned), do: "bg-slate-100 text-slate-500"
  defp status_class(_), do: "bg-slate-100 text-slate-500"

  defp status_label(:running), do: "Running"
  defp status_label(:waking), do: "Waking..."
  defp status_label(:reconnecting), do: "Reconnecting..."
  defp status_label(:provisioned), do: "Ready"
  defp status_label(:not_provisioned), do: "Setting up"
  defp status_label(:unknown), do: "Checking..."

  defp msg_class("user"), do: "bg-blue-100 text-blue-900"
  defp msg_class(_), do: "bg-slate-100 text-slate-800"

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

  defp upload_error_message({_entry, :too_large}), do: "File is too large (max 25 MB)."
  defp upload_error_message({_entry, :not_accepted}), do: "File type is not accepted."
  defp upload_error_message({_entry, err}), do: "Upload error: #{inspect(err)}"
  defp upload_error_message(:too_many_files), do: "Only one attachment per message."
  defp upload_error_message(err), do: "Upload error: #{inspect(err)}"

  defp attachment_files(%{attachments: %{"files" => files}}) when is_list(files), do: files
  defp attachment_files(_), do: []

  defp format_size(nil), do: ""
  defp format_size(bytes) when is_integer(bytes) and bytes < 1024, do: "#{bytes} B"

  defp format_size(bytes) when is_integer(bytes) and bytes < 1024 * 1024,
    do: "#{Float.round(bytes / 1024, 1)} KB"

  defp format_size(bytes) when is_integer(bytes),
    do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"
end
