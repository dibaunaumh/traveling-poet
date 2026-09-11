defmodule TravelingPoetWeb.PushNotifications do
  @moduledoc """
  The server half of browser push opt-in, shared by the journal (first-run
  nudge) and settings (per-device switch). Both LiveViews render one
  `WebPush`-hooked element and route its `push_*` events here.

  Assigns: `@push` — `%{configured?, state, dismissed?, devices}` where state is
  `:unknown` until the browser reports, then one of `:unsupported`,
  `:needs_install`, `:denied`, `:available`, `:subscribed`.
  """

  use TravelingPoetWeb, :html
  import Phoenix.LiveView, only: [put_flash: 3, get_connect_info: 2]

  alias TravelingPoet.WebPush

  @states ~w(unsupported needs_install denied available subscribed)

  def assign_push(socket) do
    user = socket.assigns.user

    assign(socket, :push, %{
      configured?: WebPush.configured?(),
      state: :unknown,
      dismissed?: false,
      devices: if(WebPush.configured?(), do: WebPush.count(user), else: 0)
    })
  end

  @doc "Handles `push_state`, `push_subscribed`, `push_unsubscribed` from the hook."
  def handle_event("push_state", %{"state" => state} = params, socket) when state in @states do
    socket =
      case {state, params["subscription"]} do
        # The browser still holds a subscription; make sure we do too.
        {"subscribed", %{} = sub} ->
          case WebPush.subscribe(socket.assigns.user, sub, user_agent: user_agent(socket)) do
            {:ok, _} -> socket
            {:error, _} -> socket
          end

        _ ->
          socket
      end

    {:noreply, set_push(socket, String.to_existing_atom(state), params["dismissed"] == true)}
  end

  def handle_event("push_subscribed", %{"subscription" => sub}, socket) do
    poet = socket.assigns[:poet]

    case WebPush.subscribe(socket.assigns.user, sub, user_agent: user_agent(socket)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> set_push(:subscribed, false)
         |> put_flash(
           :info,
           "You'll get a nudge on this device when #{(poet && poet.name) || "your poet"} publishes."
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not save this device's subscription.")}
    end
  end

  def handle_event("push_unsubscribed", params, socket) do
    if endpoint = params["endpoint"], do: WebPush.unsubscribe(socket.assigns.user, endpoint)
    {:noreply, set_push(socket, :available, false)}
  end

  def handle_event("push_" <> _, _params, socket), do: {:noreply, socket}

  defp set_push(socket, state, dismissed?) do
    push = socket.assigns.push

    assign(socket, :push, %{
      push
      | state: state,
        dismissed?: dismissed?,
        devices: WebPush.count(socket.assigns.user)
    })
  end

  defp user_agent(socket) do
    case get_connect_info(socket, :user_agent) do
      ua when is_binary(ua) -> ua
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # -- components --

  attr :push, :map, required: true
  attr :poet, :any, required: true
  attr :entry, :any, default: nil

  @doc """
  The journal's one-line invitation, shown once there is an entry to be
  nudged about and this device could receive one. "Not now" is remembered
  per device (localStorage), since the choice is about this device.
  """
  def push_nudge(assigns) do
    ~H"""
    <div
      :if={@push.configured? && @entry}
      id="push-nudge"
      phx-hook="WebPush"
      data-vapid-key={TravelingPoet.WebPush.public_key()}
    >
      <div
        :if={@push.state in [:available, :needs_install] and not @push.dismissed?}
        class="alert alert-soft text-sm mt-4 flex-wrap"
        role="status"
      >
        <.icon name="hero-bell" class="size-5 shrink-0" />
        <span :if={@push.state == :available} class="flex-1 min-w-48">
          Want a nudge when {@poet.name} writes the next entry?
        </span>
        <span :if={@push.state == :needs_install} class="flex-1 min-w-48">
          To get a nudge when {@poet.name} publishes, add Poet to your Home Screen
          (Share → Add to Home Screen), then turn on notifications from there.
        </span>
        <div class="flex items-center gap-1">
          <button
            :if={@push.state == :available}
            type="button"
            data-push-action="subscribe"
            class="btn btn-primary btn-sm"
          >
            Turn on notifications
          </button>
          <button type="button" data-push-action="dismiss" class="btn btn-ghost btn-sm opacity-60">
            Not now
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :push, :map, required: true
  attr :poet, :any, required: true

  @doc """
  The tip on the journal while the first entry is still on its way. Unlike
  the nudge it needs no entry, and it carries the promise of what a
  notification is ever for. Never render it alongside the nudge: two
  WebPush hooks on one page would both register the service worker.
  """
  def push_tip(assigns) do
    ~H"""
    <div
      :if={@push.configured?}
      id="push-tip"
      phx-hook="WebPush"
      data-vapid-key={TravelingPoet.WebPush.public_key()}
      class="text-sm space-y-2"
    >
      <p :if={@push.state == :unknown} class="opacity-60">Checking this device for notifications.</p>
      <div :if={@push.state == :available} class="space-y-2">
        <p class="font-medium">Get a nudge on this device when {@poet.name} publishes.</p>
        <button type="button" data-push-action="subscribe" class="btn btn-secondary btn-sm">
          Turn on notifications
        </button>
      </div>
      <div :if={@push.state == :needs_install} class="space-y-1">
        <p class="font-medium">Add Traveling Poet to your Home Screen.</p>
        <p class="opacity-70">
          On iPhone or iPad, notifications work once the app is on your Home Screen: tap Share,
          then Add to Home Screen, open it from there, and turn on notifications.
        </p>
      </div>
      <p :if={@push.state == :subscribed} class="font-medium">
        This device will get a nudge when the first entry is out.
      </p>
      <p :if={@push.state == :denied} class="opacity-70">
        Notifications are blocked for this site. Allow them in your browser or system settings
        to get a nudge when {@poet.name} publishes.
      </p>
      <p :if={@push.state == :unsupported} class="opacity-70">
        This browser can't receive push notifications. Telegram works everywhere.
      </p>
      <p class="opacity-60 text-xs" id="notification-promise">
        Notifications are only for new entries and notes about your account, such as credits
        running low. Never marketing.
      </p>
    </div>
    """
  end

  attr :push, :map, required: true
  attr :poet, :any, required: true

  @doc "The settings section: this device's switch plus how many devices are on."
  def push_settings(assigns) do
    ~H"""
    <div
      :if={@push.configured?}
      id="push-settings"
      phx-hook="WebPush"
      data-vapid-key={TravelingPoet.WebPush.public_key()}
    >
      <h2 class="font-semibold mb-2">Notifications</h2>
      <div class="text-sm space-y-2">
        <p :if={@push.state == :unknown} class="opacity-60">Checking this device…</p>
        <p :if={@push.state == :unsupported} class="opacity-60">
          This browser can't receive push notifications.
        </p>
        <p :if={@push.state == :needs_install} class="opacity-80">
          On iPhone and iPad, notifications work once Poet is on your Home Screen:
          tap Share → Add to Home Screen, open it from there, and come back to this page.
        </p>
        <p :if={@push.state == :denied} class="opacity-80">
          Notifications are blocked for this site. Allow them in your browser or system
          settings, then reload this page.
        </p>
        <div :if={@push.state == :available} class="flex items-center gap-3 flex-wrap">
          <span>Nudge this device when {(@poet && @poet.name) || "your poet"} publishes</span>
          <button type="button" data-push-action="subscribe" class="btn btn-secondary btn-sm">
            Turn on
          </button>
        </div>
        <div :if={@push.state == :subscribed} class="flex items-center gap-3 flex-wrap">
          <span>This device gets a nudge when a new entry is published ✓</span>
          <button type="button" data-push-action="unsubscribe" class="btn btn-outline btn-sm">
            Turn off
          </button>
        </div>
        <p :if={@push.devices > 0} class="text-xs opacity-60" id="push-device-count">
          {@push.devices} {if @push.devices == 1, do: "device is", else: "devices are"} subscribed.
        </p>
      </div>
    </div>
    """
  end
end
