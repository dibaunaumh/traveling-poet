defmodule TravelingPoetWeb.TripSuggestions do
  @moduledoc """
  The LiveView half of calendar trips, shared by the journal (a nudge when
  a trip has been found) and settings (the Trips card: home city, the
  calendar connection, suggested and planned trips). Both LiveViews
  subscribe to the user topic, route `trip_*` events and the
  `{:trips_updated}` broadcast here, and render one of the components.

  Assigns: `@trips`, see `assign_trips/1`.
  """

  use TravelingPoetWeb, :html
  import Phoenix.LiveView, only: [put_flash: 3]

  alias TravelingPoet.{Accounts, Geocoder, GoogleAuth, GoogleCalendar, Trips}
  alias TravelingPoet.Trips.{CalendarSync, Trip}

  # "Check now" at most this often; the scheduled sync covers the rest.
  @check_again_after_s 10 * 60

  def assign_trips(socket) do
    user = Accounts.get_user!(socket.assigns.user.id)
    poet = socket.assigns[:poet]

    assign(socket, :trips, %{
      enabled?: Trips.enabled_for?(user),
      connected?: GoogleCalendar.connected?(user),
      connected_at: user.calendar_connected_at,
      synced_at: user.calendar_synced_at,
      error: user.calendar_error,
      home: home(user),
      home_query: "",
      home_results: [],
      home_error: nil,
      suggested: (poet && Trips.suggested(poet.id)) || [],
      planned: (poet && Trips.list_by_status(poet.id, ~w(planned scouting))) || []
    })
  end

  defp home(%{home_lat: lat, home_lng: lng} = user) when is_number(lat) and is_number(lng),
    do: %{place_name: user.home_place_name, lat: lat, lng: lng}

  defp home(_user), do: nil

  @doc "Handles every `trip_*` event from the nudge and the card."
  def handle_event("trip_search_home", %{"query" => query}, socket) do
    case String.trim(query) do
      "" ->
        {:noreply, socket}

      q ->
        case Geocoder.Limiter.search(q) do
          {:ok, results} ->
            {:noreply,
             update_trips(socket, %{
               home_query: q,
               home_results: results,
               home_error: if(results == [], do: "No places found.")
             })}

          {:error, reason} ->
            {:noreply, update_trips(socket, %{home_error: "Search failed: #{reason}"})}
        end
    end
  end

  def handle_event("trip_pick_home", %{"idx" => idx}, socket) do
    with result when not is_nil(result) <-
           Enum.at(socket.assigns.trips.home_results, String.to_integer(idx)),
         {:ok, user} <-
           Accounts.update_user(Accounts.get_user!(socket.assigns.user.id), %{
             home_place_name: result.place_name,
             home_lat: result.lat,
             home_lng: result.lng,
             home_country_code: result.country_code
           }) do
      if GoogleCalendar.connected?(user), do: CalendarSync.sync_soon(user)
      {:noreply, socket |> assign(:user, user) |> assign_trips()}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("trip_accept", %{"id" => id}, socket) do
    poet = socket.assigns.poet

    with %Trip{status: "suggested"} = trip <- Trips.get(poet.id, String.to_integer(id)),
         {:ok, trip} <- Trips.accept(poet, trip) do
      {:noreply,
       socket
       |> assign_trips()
       |> put_flash(:info, "#{poet.name} will scout #{trip.name} for your trip.")}
    else
      _ -> {:noreply, assign_trips(socket)}
    end
  end

  def handle_event("trip_dismiss", %{"id" => id}, socket) do
    poet = socket.assigns.poet

    with %Trip{status: "suggested"} = trip <- Trips.get(poet.id, String.to_integer(id)),
         {:ok, _} <- Trips.dismiss(trip) do
      {:noreply, assign_trips(socket)}
    else
      _ -> {:noreply, assign_trips(socket)}
    end
  end

  def handle_event("trip_cancel", %{"id" => id}, socket) do
    poet = socket.assigns.poet

    with %Trip{} = trip <- Trips.get(poet.id, String.to_integer(id)),
         true <- trip.status in ~w(planned scouting),
         {:ok, _} <- Trips.cancel(poet, trip) do
      {:noreply,
       socket
       |> assign_trips()
       |> put_flash(:info, "The trip to #{trip.name} is called off.")}
    else
      _ -> {:noreply, assign_trips(socket)}
    end
  end

  def handle_event("trip_sync_now", _params, socket) do
    user = Accounts.get_user!(socket.assigns.user.id)
    synced_at = user.calendar_synced_at

    cond do
      not GoogleCalendar.connected?(user) ->
        {:noreply, socket}

      synced_at && DateTime.diff(DateTime.utc_now(), synced_at) < @check_again_after_s ->
        {:noreply,
         put_flash(socket, :info, "Your calendar was checked a few minutes ago. Try again later.")}

      true ->
        CalendarSync.sync_soon(user)
        {:noreply, socket |> assign_trips() |> put_flash(:info, "Checking your calendar.")}
    end
  end

  def handle_event("trip_disconnect", _params, socket) do
    user = Accounts.get_user!(socket.assigns.user.id)
    {:ok, user} = GoogleAuth.disconnect(user, :calendar)
    if poet = socket.assigns[:poet], do: Trips.withdraw_suggestions(poet.id)

    {:noreply,
     socket
     |> assign(:user, user)
     |> assign_trips()
     |> put_flash(:info, "Google Calendar disconnected. Trips already planned stay planned.")}
  end

  def handle_event("trip_" <> _, _params, socket), do: {:noreply, socket}

  @doc "A sync, an accept or a dismissal changed this companion's trips."
  def handle_info({:trips_updated}, socket), do: {:noreply, assign_trips(socket)}

  defp update_trips(socket, changes),
    do: assign(socket, :trips, Map.merge(socket.assigns.trips, changes))

  # -- components --

  attr :trips, :map, required: true
  attr :poet, :any, required: true

  @doc "The journal's invitation: the nearest trip found on the calendar, to scout or not."
  def trip_nudge(assigns) do
    assigns = assign(assigns, :trip, List.first(assigns.trips.suggested))

    ~H"""
    <div :if={@trip} id="trip-nudge" class="alert alert-soft text-sm mt-4 flex-wrap" role="status">
      <.icon name="hero-map" class="size-5 shrink-0" />
      <span class="flex-1 min-w-48">
        Your calendar has a trip to {@trip.name}, {Trips.date_range(@trip.start_date, @trip.end_date)}.
        Should {@poet.name} scout it first?
      </span>
      <div class="flex items-center gap-1">
        <button
          type="button"
          phx-click="trip_accept"
          phx-value-id={@trip.id}
          class="btn btn-primary btn-sm"
          id={"trip-nudge-accept-#{@trip.id}"}
        >
          Scout this trip
        </button>
        <button
          type="button"
          phx-click="trip_dismiss"
          phx-value-id={@trip.id}
          class="btn btn-ghost btn-sm opacity-60"
          id={"trip-nudge-dismiss-#{@trip.id}"}
        >
          Not this trip
        </button>
      </div>
    </div>
    """
  end

  attr :trips, :map, required: true
  attr :user, :any, required: true
  attr :poet, :any, required: true

  @doc "The settings card: home, the calendar connection, and every open trip."
  def trip_settings(assigns) do
    ~H"""
    <div :if={@trips.enabled?} id="trip-settings" class="space-y-4 text-sm">
      <p class="opacity-70">
        Connect your Google Calendar and {@poet.name} will notice the trips on it and offer to
        scout them before you go. Only your primary calendar is read, and only the dates and
        places of trips are kept, never what an event says.
      </p>

      <div id="trip-home">
        <h3 class="font-medium mb-1">Home</h3>
        <p :if={@trips.home} class="flex items-center gap-2 flex-wrap">
          <span>{@trips.home.place_name}</span>
        </p>
        <p :if={is_nil(@trips.home)} class="opacity-70 mb-2">
          Where do you set out from? A trip is time spent far from here.
        </p>
        <form phx-submit="trip_search_home" class="flex gap-2 mt-2">
          <input
            type="text"
            name="query"
            value={@trips.home_query}
            class="input input-bordered input-sm flex-1"
            placeholder={if @trips.home, do: "Change your home city", else: "Your home city"}
          />
          <button type="submit" class="btn btn-sm">Search</button>
        </form>
        <p :if={@trips.home_error} class="text-error text-xs mt-1">{@trips.home_error}</p>
        <div :if={@trips.home_results != []} class="space-y-1 mt-2">
          <button
            :for={{result, idx} <- Enum.with_index(@trips.home_results)}
            phx-click="trip_pick_home"
            phx-value-idx={idx}
            class="btn btn-outline btn-xs w-full justify-start text-left normal-case"
          >
            {result.place_name}
          </button>
        </div>
      </div>

      <div id="trip-calendar">
        <h3 class="font-medium mb-1">Google Calendar</h3>
        <div :if={!@trips.connected?}>
          <p :if={is_nil(@trips.home)} class="opacity-70">Pick your home city first.</p>
          <.link
            :if={@trips.home}
            href={~p"/settings/calendar/connect"}
            class="btn btn-secondary btn-sm"
            id="connect-calendar"
          >
            Connect Google Calendar
          </.link>
          <p :if={@trips.home} class="text-xs opacity-60 mt-1">
            Google will ask you to allow reading your calendar, alongside anything you have
            already allowed, such as Google Drive.
          </p>
        </div>
        <div :if={@trips.connected?} class="space-y-2">
          <p :if={@trips.error == "reconnect"} class="text-warning">
            The connection to your calendar has lapsed.
            <.link href={~p"/settings/calendar/connect"} class="link" id="reconnect-calendar">
              Reconnect
            </.link>
          </p>
          <p :if={@trips.error == "forbidden"} class="text-warning">
            Google would not let the poet read your calendar. Try reconnecting.
          </p>
          <p :if={@trips.error == "failed"} class="opacity-70">
            The last check failed; it will be tried again.
          </p>
          <p class="opacity-70" id="calendar-status">
            Connected<span :if={@trips.synced_at}>, last checked {ago(@trips.synced_at)}</span>.
          </p>
          <div class="flex items-center gap-2 flex-wrap">
            <button
              type="button"
              phx-click="trip_sync_now"
              class="btn btn-outline btn-xs"
              id="sync-calendar"
            >
              Check now
            </button>
            <button
              type="button"
              phx-click="trip_disconnect"
              class="link text-xs opacity-60"
              id="disconnect-calendar"
            >
              Disconnect Google Calendar
            </button>
          </div>
        </div>
      </div>

      <div :if={@trips.suggested != []} id="trip-suggested">
        <h3 class="font-medium mb-1">Found on your calendar</h3>
        <ul class="space-y-2">
          <li
            :for={trip <- @trips.suggested}
            class="p-3 rounded-lg bg-base-200"
            id={"trip-#{trip.id}"}
          >
            <div class="flex items-center gap-2 flex-wrap">
              <span class="font-medium">{trip.name}</span>
              <span class="opacity-70">{Trips.date_range(trip.start_date, trip.end_date)}</span>
              <span :if={trip.changed_at} class="badge badge-ghost badge-xs">updated</span>
            </div>
            <p :if={length(Trip.destinations(trip)) > 1} class="text-xs opacity-60 mt-1">
              {Enum.map_join(Trip.destinations(trip), ", then ", & &1["place_name"])}
            </p>
            <div class="flex items-center gap-1 mt-2">
              <button
                type="button"
                phx-click="trip_accept"
                phx-value-id={trip.id}
                class="btn btn-primary btn-xs"
                id={"trip-accept-#{trip.id}"}
              >
                Scout this trip
              </button>
              <button
                type="button"
                phx-click="trip_dismiss"
                phx-value-id={trip.id}
                class="btn btn-ghost btn-xs opacity-60"
                id={"trip-dismiss-#{trip.id}"}
              >
                Not this trip
              </button>
            </div>
          </li>
        </ul>
      </div>

      <div :if={@trips.planned != []} id="trip-planned">
        <h3 class="font-medium mb-1">Planned</h3>
        <ul class="space-y-2">
          <li :for={trip <- @trips.planned} class="p-3 rounded-lg bg-base-200" id={"trip-#{trip.id}"}>
            <div class="flex items-center gap-2 flex-wrap">
              <span class="font-medium">{trip.name}</span>
              <span class="opacity-70">{Trips.date_range(trip.start_date, trip.end_date)}</span>
            </div>
            <p class="text-xs opacity-60 mt-1">Its stops are on the itinerary above.</p>
            <button
              type="button"
              phx-click="trip_cancel"
              phx-value-id={trip.id}
              class="link text-xs opacity-60 mt-1"
              id={"trip-cancel-#{trip.id}"}
            >
              Call it off
            </button>
          </li>
        </ul>
      </div>

      <p
        :if={@trips.connected? and @trips.suggested == [] and @trips.planned == []}
        class="opacity-60"
      >
        No upcoming trips found yet. Trips need a place and at least two days, or a booking
        Gmail put on your calendar.
      </p>
    </div>
    """
  end

  defp ago(%DateTime{} = at) do
    minutes = div(DateTime.diff(DateTime.utc_now(), at), 60)

    cond do
      minutes < 1 -> "just now"
      minutes < 60 -> "#{minutes} min ago"
      minutes < 60 * 24 -> "#{div(minutes, 60)} h ago"
      true -> "#{div(minutes, 60 * 24)} d ago"
    end
  end
end
