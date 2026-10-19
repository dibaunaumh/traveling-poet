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

  alias TravelingPoet.{Apns, WebPush}

  @states ~w(unsupported needs_install denied available subscribed)

  # Inside the iOS app the same switch, nudge and states run over Apple's push
  # service instead of Web Push, which a web view does not have. The hook
  # reports a `device` (an APNs token) where a browser reports a
  # `subscription`; everything else is shared.
  def assign_push(socket) do
    user = socket.assigns.user
    configured? = if native?(socket), do: Apns.configured?(), else: WebPush.configured?()

    assign(socket, :push, %{
      configured?: configured?,
      # the wording differs: there is no "browser" or "site" inside the app
      native?: native?(socket),
      state: :unknown,
      dismissed?: false,
      devices: if(configured?, do: device_count(user), else: 0)
    })
  end

  defp native?(socket), do: socket.assigns[:native_app] == true

  defp device_count(user), do: WebPush.count(user) + Apns.count(user)

  defp register_device(socket, %{"token" => token} = device),
    do: Apns.register(socket.assigns.user, token, device["environment"])

  defp register_device(_socket, _device), do: {:error, :invalid}

  @doc "Handles `push_state`, `push_subscribed`, `push_unsubscribed` from the hook."
  def handle_event(
        "push_state",
        %{"state" => "subscribed", "device" => %{} = device} = params,
        socket
      ) do
    # The phone still has its token; make sure we do too (and under this account).
    register_device(socket, device)
    {:noreply, set_push(socket, :subscribed, params["dismissed"] == true)}
  end

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

  def handle_event("push_subscribed", %{"device" => %{} = device}, socket) do
    poet = socket.assigns[:poet]

    case register_device(socket, device) do
      {:ok, _} ->
        {:noreply,
         socket
         |> set_push(:subscribed, false)
         |> put_flash(
           :info,
           dgettext(
             "journal",
             "You'll get a notification on this device when %{poet} publishes.",
             poet: (poet && poet.name) || dgettext("journal", "your poet")
           )
         )}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           dgettext("journal", "Could not turn notifications on for this device.")
         )}
    end
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
           dgettext("journal", "You'll get a nudge on this device when %{poet} publishes.",
             poet: (poet && poet.name) || dgettext("journal", "your poet")
           )
         )}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           dgettext("journal", "Could not save this device's subscription.")
         )}
    end
  end

  def handle_event("push_unsubscribed", params, socket) do
    if endpoint = params["endpoint"], do: WebPush.unsubscribe(socket.assigns.user, endpoint)
    if token = params["device_token"], do: Apns.unregister(socket.assigns.user, token)
    {:noreply, set_push(socket, :available, false)}
  end

  def handle_event("push_" <> _, _params, socket), do: {:noreply, socket}

  defp set_push(socket, state, dismissed?) do
    push = socket.assigns.push

    assign(socket, :push, %{
      push
      | state: state,
        dismissed?: dismissed?,
        devices: device_count(socket.assigns.user)
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
  attr :next, :map, default: nil, doc: "`NextPage.for/1`, set under the latest page only"

  @doc """
  The line under the reader's latest page: when the next one comes and from
  where (the time is rewritten into the reader's own zone by the LocalTime
  hook), then, if this device could get a notification, the offer to send
  one. The offer sits here because this is the moment the reader wants the
  next page. "Not now" is remembered per device (localStorage): the offer
  comes back once a day later, and a second "Not now" is final.
  """
  def push_nudge(assigns) do
    ~H"""
    <div
      :if={@entry && @next}
      id="push-nudge"
      class="border-t border-base-300 pt-3 mt-4 text-sm"
      phx-hook={@push.configured? && "WebPush"}
      data-vapid-key={@push.configured? && TravelingPoet.WebPush.public_key()}
    >
      <p id="next-page-line" class="opacity-80">
        <.rich text={next_line(@next)}>
          <:part name="time">
            <time
              id="next-page-at"
              phx-hook="LocalTime"
              datetime={DateTime.to_iso8601(@next.at)}
            >{dgettext("notify", "%{date} around %{time} UTC",
              date: TravelingPoet.Locale.format_date(@next.at, :day_mon),
              time: TravelingPoet.Locale.format_date(@next.at, :time)
            )}</time>
          </:part>
        </.rich>
      </p>
      <div
        :if={
          @push.configured? and @push.state in [:available, :needs_install] and
            not @push.dismissed?
        }
        class="flex flex-wrap items-center gap-2 mt-2"
        role="status"
      >
        <button
          :if={@push.state == :available}
          type="button"
          data-push-action="subscribe"
          class="btn btn-primary btn-sm"
        >
          <.icon name="hero-bell" class="size-4" /> {dgettext("journal", "Get it the moment it lands")}
        </button>
        <span :if={@push.state == :needs_install} class="flex-1 min-w-48 opacity-80">
          {dgettext(
            "journal",
            "To get it the moment it lands, use Share, then Add to Home Screen, and turn on notifications from there."
          )}
        </span>
        <button type="button" data-push-action="dismiss" class="btn btn-ghost btn-sm opacity-60">
          {dgettext("journal", "Not now")}
        </button>
        <.expect channel={:push} name={@poet.name} id="push-nudge-expect" />
      </div>
    </div>
    """
  end

  # The line under the latest page, whole: the time is a part (the LocalTime
  # hook rewrites it), the place a value.
  defp next_line(%{place: place}) when is_binary(place),
    do:
      dgettext("journal", "Next page: %{time}, from %{place}.", time: marker(:time), place: place)

  defp next_line(%{moving?: true}),
    do: dgettext("journal", "Next page: %{time}, from somewhere new.", time: marker(:time))

  defp next_line(_), do: dgettext("journal", "Next page: %{time}.", time: marker(:time))

  attr :channel, :atom, required: true, values: [:push, :telegram, :email]
  attr :name, :string, default: nil
  attr :id, :string, default: nil

  @doc """
  What a channel will send and how often, in one line under every offer. A
  reader said the offers never told her how often, or for what. Keep it true
  to what the notifiers send: a page a day (WebPush/Telegram/Email
  notifiers), the poet's question (`Asks.Cadence`, at most weekly), and on
  Telegram a low-credits note. Trips and books only follow something the
  reader started, so they go unmentioned.
  """
  def expect(assigns) do
    assigns =
      assign(
        assigns,
        :text,
        expect_text(assigns.channel, assigns.name || dgettext("journal", "your poet"))
      )

    ~H"""
    <p id={@id} class="text-xs opacity-60">{@text}</p>
    """
  end

  def expect_text(:push, name),
    do:
      dgettext(
        "journal",
        "One a day, when %{name} publishes a new page, and now and then a question from %{name}, never more than once a week. Never marketing.",
        name: name
      )

  def expect_text(:telegram, name),
    do:
      dgettext(
        "journal",
        "One message a day, when %{name} publishes a new page, now and then a question from %{name}, never more than once a week, and a note if your credits run low. Never marketing.",
        name: name
      )

  def expect_text(:email, name),
    do:
      dgettext("journal", "One email a day, only when %{name} publishes a new page.", name: name)

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
      <p :if={@push.state == :unknown} class="opacity-60">
        {dgettext("journal", "Checking this device for notifications.")}
      </p>
      <div :if={@push.state == :available} class="space-y-2">
        <p class="font-medium">
          {dgettext("journal", "Get a notification on this device when %{poet} publishes.",
            poet: @poet.name
          )}
        </p>
        <button type="button" data-push-action="subscribe" class="btn btn-secondary btn-sm">
          {dgettext("journal", "Turn on notifications")}
        </button>
      </div>
      <div :if={@push.state == :needs_install} class="space-y-1">
        <p class="font-medium">{dgettext("journal", "Add Traveling Poet to your Home Screen.")}</p>
        <p class="opacity-70">
          {dgettext(
            "journal",
            "On iPhone or iPad, notifications work once the app is on your Home Screen: tap Share, then Add to Home Screen, open it from there, and turn on notifications."
          )}
        </p>
      </div>
      <p :if={@push.state == :subscribed} class="font-medium">
        {dgettext("journal", "This device will get a nudge when the first entry is out.")}
      </p>
      <p :if={@push.state == :denied and !@push.native?} class="opacity-70">
        {dgettext(
          "journal",
          "Notifications are blocked for this site. Allow them in your browser or system settings to get a nudge when %{poet} publishes.",
          poet: @poet.name
        )}
      </p>
      <p :if={@push.state == :denied and @push.native?} class="opacity-70">
        {dgettext(
          "journal",
          "Notifications are turned off for Traveling Poet. Turn them on in the Settings app, under Notifications, to hear when %{poet} publishes.",
          poet: @poet.name
        )}
      </p>
      <p :if={@push.state == :unsupported and !@push.native?} class="opacity-70">
        {dgettext(
          "journal",
          "This browser can't receive push notifications. Telegram works everywhere."
        )}
      </p>
      <p :if={@push.state == :unsupported and @push.native?} class="opacity-70">
        {dgettext(
          "journal",
          "Notifications are not available on this device right now. Telegram works everywhere."
        )}
      </p>
      <.expect channel={:push} name={@poet.name} id="notification-promise" />
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
      <h2 class="font-semibold mb-2">{dgettext("journal", "This device")}</h2>
      <div class="text-sm space-y-2">
        <.expect channel={:push} name={@poet && @poet.name} id="push-settings-expect" />
        <p :if={@push.state == :unknown} class="opacity-60">
          {dgettext("journal", "Checking this device…")}
        </p>
        <p :if={@push.state == :unsupported and !@push.native?} class="opacity-60">
          {dgettext("journal", "This browser can't receive push notifications.")}
        </p>
        <p :if={@push.state == :unsupported and @push.native?} class="opacity-60">
          {dgettext("journal", "Notifications are not available on this device right now.")}
        </p>
        <p :if={@push.state == :needs_install} class="opacity-80">
          {dgettext(
            "journal",
            "On iPhone and iPad, notifications work once Poet is on your Home Screen: tap Share → Add to Home Screen, open it from there, and come back to this page."
          )}
        </p>
        <p :if={@push.state == :denied and !@push.native?} class="opacity-80">
          {dgettext(
            "journal",
            "Notifications are blocked for this site. Allow them in your browser or system settings, then reload this page."
          )}
        </p>
        <p :if={@push.state == :denied and @push.native?} class="opacity-80">
          {dgettext(
            "journal",
            "Notifications are turned off for Traveling Poet. Turn them on in the Settings app, under Notifications, then come back here."
          )}
        </p>
        <div :if={@push.state == :available} class="flex items-center gap-3 flex-wrap">
          <span>
            {dgettext("journal", "Nudge this device when %{poet} publishes",
              poet: (@poet && @poet.name) || dgettext("journal", "your poet")
            )}
          </span>
          <button type="button" data-push-action="subscribe" class="btn btn-secondary btn-sm">
            {dgettext("journal", "Turn on")}
          </button>
        </div>
        <div :if={@push.state == :subscribed} class="flex items-center gap-3 flex-wrap">
          <span>
            <.icon name="hero-check-circle-mini" class="size-4 -mt-0.5 text-success" />
            {dgettext("journal", "This device gets a nudge when a new entry is published")}
          </span>
          <button type="button" data-push-action="unsubscribe" class="btn btn-outline btn-sm">
            {dgettext("journal", "Turn off")}
          </button>
        </div>
        <p :if={@push.devices > 0} class="text-xs opacity-60" id="push-device-count">
          {dngettext(
            "journal",
            "%{count} device is subscribed.",
            "%{count} devices are subscribed.",
            @push.devices
          )}
        </p>
      </div>
    </div>
    """
  end
end
