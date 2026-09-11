defmodule TravelingPoetWeb.TelegramPairing do
  @moduledoc """
  The LiveView half of Telegram pairing, shared by the journal (a tip while
  the first entry is on its way) and settings (the permanent switch). Both
  LiveViews subscribe to the user topic, route `telegram_*` events and the
  `{:telegram_paired, _}` broadcast here, and render one of the components.

  Assigns: `@telegram` - `%{configured?, link}` where `link` is the minted
  `t.me` deep link, or nil until the user asks for one. Pairing state itself
  is read from `@user` (`telegram_chat_id`, `telegram_username`).
  """

  use TravelingPoetWeb, :html
  import Phoenix.LiveView, only: [put_flash: 3]

  alias TravelingPoet.Accounts
  alias TravelingPoet.Telegram

  def assign_telegram(socket) do
    assign(socket, :telegram, %{configured?: Telegram.Client.configured?(), link: nil})
  end

  @doc "Handles `telegram_pair_link` and `telegram_unpair`."
  def handle_event("telegram_pair_link", _params, socket) do
    case Telegram.Pairing.mint_pair_link(socket.assigns.user) do
      {:ok, link} ->
        {:noreply, assign(socket, :telegram, %{socket.assigns.telegram | link: link})}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not create a pairing link.")}
    end
  end

  def handle_event("telegram_unpair", _params, socket) do
    case Telegram.Pairing.unpair(socket.assigns.user) do
      {:ok, user} ->
        {:noreply, socket |> assign(:user, user) |> put_flash(:info, "Telegram unpaired.")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("telegram_" <> _, _params, socket), do: {:noreply, socket}

  @doc "The poller completed a pairing for this user."
  def handle_info({:telegram_paired, _username}, socket) do
    {:noreply,
     socket
     |> assign(:user, Accounts.get_user!(socket.assigns.user.id))
     |> assign(:telegram, %{socket.assigns.telegram | link: nil})
     |> put_flash(:info, "Telegram paired.")}
  end

  # -- components --

  attr :telegram, :map, required: true
  attr :user, :any, required: true

  @doc "The settings section: paired state, unpair, or mint a link."
  def telegram_settings(assigns) do
    ~H"""
    <h2 class="font-semibold mb-2">Telegram</h2>
    <div :if={!@telegram.configured?} class="text-sm opacity-60">
      Telegram isn't configured on this server.
    </div>
    <div :if={@telegram.configured?}>
      <div :if={@user.telegram_chat_id} class="flex items-center gap-3">
        <span class="text-sm">
          Paired{if @user.telegram_username, do: " as @#{@user.telegram_username}"}
        </span>
        <button phx-click="telegram_unpair" class="btn btn-outline btn-sm">Unpair</button>
      </div>
      <div :if={is_nil(@user.telegram_chat_id)} class="space-y-2">
        <button phx-click="telegram_pair_link" class="btn btn-secondary btn-sm">
          Generate pairing link
        </button>
        <div :if={@telegram.link}>
          <a href={@telegram.link} target="_blank" rel="noopener" class="link break-all">
            {@telegram.link}
          </a>
        </div>
      </div>
    </div>
    """
  end

  attr :telegram, :map, required: true
  attr :user, :any, required: true
  attr :poet, :any, required: true

  @doc """
  The journal's tip while the first entry is on its way: pair right here,
  without a trip to settings. Renders nothing when the bot is not configured.
  """
  def telegram_tip(assigns) do
    ~H"""
    <div :if={@telegram.configured?} id="telegram-tip" class="text-sm space-y-2">
      <div :if={@user.telegram_chat_id}>
        <p class="font-medium">
          Telegram is paired{if @user.telegram_username, do: " as @#{@user.telegram_username}"}.
        </p>
        <p class="opacity-70">
          {@poet.name} will write to you there when the first entry is out.
        </p>
      </div>
      <div :if={is_nil(@user.telegram_chat_id)} class="space-y-2">
        <p class="font-medium">Get the first entry on Telegram.</p>
        <p class="opacity-70">
          Pair once and {@poet.name} will message you there whenever a page is published.
        </p>
        <button
          :if={is_nil(@telegram.link)}
          phx-click="telegram_pair_link"
          class="btn btn-secondary btn-sm"
        >
          Pair Telegram
        </button>
        <div :if={@telegram.link} class="space-y-1">
          <p>Open Telegram and press Start:</p>
          <a href={@telegram.link} target="_blank" rel="noopener" class="link break-all">
            {@telegram.link}
          </a>
          <p class="opacity-60 text-xs">This page updates by itself once you are paired.</p>
        </div>
      </div>
    </div>
    """
  end
end
