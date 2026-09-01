defmodule TravelingPoetWeb.GuideLive do
  @moduledoc """
  The trip guide: the concrete places the poet found, as map, list, and
  itinerary.

  A separate LiveView rather than a tab inside JournalLive, which already
  carries the chat sidebar, uploads, keepalive timers and the provisioning
  state machine. Keeping the guide out of it also buys shareable URLs --
  view, filter and stay all live in the query string.
  """

  use TravelingPoetWeb, :live_view

  alias TravelingPoet.{Guide, Journal, Poets}
  alias TravelingPoet.Guide.Place

  @views ~w(map list itinerary)
  # List, not map, is the default: coordinates arrive asynchronously and are
  # allowed to fail, so list is the view that always has something in it.
  @default_view "list"

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    poet = user.onboarding_completed && Poets.get_poet_by_user(user.id)

    if poet do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "poet:#{poet.id}")
      end

      {:ok, assign(socket, poet: poet, page_title: "Trip guide")}
    else
      {:ok, push_navigate(socket, to: ~p"/onboarding")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # Whitelisted, never String.to_atom on user input.
    view = param(params, "view", @views, @default_view)
    filter = param(params, "filter", Guide.filter_groups(), "all")

    {:noreply,
     socket
     |> assign(:view, view)
     |> assign(:filter, filter)
     |> assign_stay(params["stay"])
     |> assign_places()}
  end

  defp param(params, key, allowed, default) do
    case params[key] do
      value when is_binary(value) -> if value in allowed, do: value, else: default
      _ -> default
    end
  end

  defp assign_stay(socket, requested) do
    stays = Guide.list_stays(socket.assigns.poet.id)

    stay =
      Enum.find(stays, fn s -> to_string(s.id) == requested end) ||
        default_stay(stays, socket.assigns.poet)

    socket |> assign(:stays, stays) |> assign(:stay, stay)
  end

  # Prefer the stay the poet is on now, but fall back to the most recent one
  # that actually has places. A poet who arrived somewhere yesterday would
  # otherwise open the guide to an empty page while its whole trip sits one
  # click away.
  defp default_stay(stays, poet) do
    current = Poets.current_path_point(poet.id)

    Enum.find(stays, &(current && &1.id == current.id)) || List.first(stays)
  end

  defp assign_places(socket) do
    %{poet: poet, stay: stay, filter: filter} = socket.assigns

    all = Guide.list_places(poet.id, path_point_id: stay_id(stay))
    shown = if filter == "all", do: all, else: Enum.filter(all, &in_group?(&1, filter))

    socket
    |> assign(:counts, Guide.counts_by_group(all))
    |> assign(:places, shown)
    |> assign(:days, Guide.group_by_day(shown))
    |> assign(:map_places, Guide.map_payload(shown, poet.name))
    |> assign(:unmapped, Guide.unmapped_count(shown))
    |> assign(:media, media_for(shown))
  end

  defp stay_id(nil), do: :any
  defp stay_id(stay), do: stay.id

  defp in_group?(place, group), do: Place.group_for(place.category) == group

  defp media_for(places) do
    places
    |> Enum.map(& &1.media_id)
    |> Enum.reject(&is_nil/1)
    |> Map.new(&{&1, Journal.get_media(&1)})
  end

  @impl true
  def handle_event("set_view", %{"view" => view}, socket),
    do: {:noreply, push_patch(socket, to: guide_path(socket, view: view))}

  def handle_event("set_filter", %{"filter" => filter}, socket),
    do: {:noreply, push_patch(socket, to: guide_path(socket, filter: filter))}

  def handle_event("set_stay", %{"stay" => stay}, socket),
    do: {:noreply, push_patch(socket, to: guide_path(socket, stay: stay))}

  # The map pushes a selection back up so the detail card can render server-side.
  def handle_event("select_place", %{"id" => id}, socket) do
    {:noreply, assign(socket, :selected, Enum.find(socket.assigns.places, &(&1.id == id)))}
  end

  @impl true
  def handle_info({:guide_geocoded, _poet_id}, socket),
    do: {:noreply, socket |> assign_places() |> push_map()}

  def handle_info({:journal_published, _id}, socket),
    do: {:noreply, socket |> assign_places() |> push_map()}

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp push_map(socket) do
    # phx-update="ignore" means the data attribute alone will not re-render the
    # map, so changes go through the hook's own event.
    push_event(socket, "map:update", %{places: socket.assigns.map_places})
  end

  defp guide_path(socket, overrides) do
    %{view: view, filter: filter, stay: stay} = socket.assigns

    query =
      %{"view" => view, "filter" => filter, "stay" => stay && to_string(stay.id)}
      |> Map.merge(Map.new(overrides, fn {k, v} -> {to_string(k), to_string(v)} end))
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)

    ~p"/guide?#{query}"
  end

  ## Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active_tab={:guide}>
      <div class="flex flex-wrap items-end justify-between gap-4 mb-4">
        <div>
          <h1 class="text-2xl font-semibold">Trip guide</h1>
          <p class="text-sm opacity-60 mt-1">
            Places, food and events <span :if={@stay}>for {@stay.place_name}</span>
            <span :if={is_nil(@stay)}>from {@poet.name}'s travels</span>
          </p>
        </div>

        <div id="guide-views" class="flex gap-1 bg-base-200 rounded-full p-1">
          <button
            :for={{key, label} <- [{"map", "Map"}, {"list", "List"}, {"itinerary", "Itinerary"}]}
            id={"guide-view-#{key}"}
            phx-click="set_view"
            phx-value-view={key}
            class={[
              "btn btn-sm rounded-full border-none",
              if(@view == key, do: "btn-primary", else: "btn-ghost")
            ]}
          >
            {label}
          </button>
        </div>
      </div>

      <div id="guide-filters" class="flex flex-wrap gap-2 mb-4">
        <button
          :for={
            {key, label} <- [
              {"all", "All"},
              {"food", "Food"},
              {"sights", "Sights"},
              {"events", "Events"}
            ]
          }
          id={"guide-filter-#{key}"}
          phx-click="set_filter"
          phx-value-filter={key}
          class={["btn btn-sm", if(@filter == key, do: "btn-primary", else: "btn-ghost")]}
        >
          {label}
          <span class="opacity-50 text-xs">{@counts[key]}</span>
        </button>
      </div>

      <div :if={length(@stays) > 1} id="guide-stays" class="flex flex-wrap gap-2 mb-6">
        <button
          :for={stay <- @stays}
          id={"guide-stay-#{stay.id}"}
          phx-click="set_stay"
          phx-value-stay={stay.id}
          class={[
            "btn btn-xs",
            if(@stay && @stay.id == stay.id, do: "btn-secondary", else: "btn-outline")
          ]}
        >
          {stay.place_name}
        </button>
      </div>

      <div :if={@places == []} id="guide-empty" class="text-center py-16 opacity-70">
        <.icon name="hero-map" class="size-8 mb-3 opacity-50" />
        <div class="font-semibold">Still gathering recommendations</div>
        <p class="text-sm mt-1">
          {@poet.name} hasn't mapped out this trip's guide yet — it fills in as the journal grows.
        </p>
      </div>

      <div :if={@places != []}>
        <.map_view :if={@view == "map"} {assigns} />
        <.list_view :if={@view == "list"} {assigns} />
        <.itinerary_view :if={@view == "itinerary"} {assigns} />
      </div>
    </Layouts.app>
    """
  end

  # Rendered only while selected so Leaflet initialises in a visible container;
  # a map mounted hidden comes up grey until invalidateSize().
  defp map_view(assigns) do
    ~H"""
    <div class="grid gap-5 lg:grid-cols-2 items-start">
      <div
        id="guide-map"
        phx-hook="PoetMap"
        phx-update="ignore"
        data-places={Jason.encode!(@map_places)}
        class="h-[420px] rounded-2xl overflow-hidden border border-base-300"
      >
      </div>

      <div>
        <.place_card
          :if={assigns[:selected]}
          place={@selected}
          media={@media[@selected.media_id]}
          poet={@poet}
        />
        <p :if={is_nil(assigns[:selected])} class="text-sm opacity-60 p-4">
          Pick a pin to see what {@poet.name} said about it.
        </p>
      </div>
    </div>

    <p :if={@unmapped > 0} class="text-xs opacity-50 mt-3">
      {unmapped_note(@unmapped)}
    </p>
    """
  end

  defp list_view(assigns) do
    ~H"""
    <div id="guide-list" class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
      <.place_card
        :for={place <- @places}
        place={place}
        media={@media[place.media_id]}
        poet={@poet}
      />
    </div>
    """
  end

  defp itinerary_view(assigns) do
    ~H"""
    <div id="guide-itinerary" class="grid gap-8 md:grid-cols-2 lg:grid-cols-3">
      <div :for={day <- @days} id={"guide-day-#{day.day}"}>
        <div class="font-semibold">Day {day.day}</div>
        <div class="text-xs opacity-60 mb-4">{format_date(day.date)}</div>

        <div class="relative pl-6 border-l border-base-300">
          <div :for={place <- day.places} class="relative mb-5 flex gap-3">
            <span class="absolute -left-[1.85rem] top-1.5 size-3 rounded-full bg-secondary ring-2 ring-base-100"></span>
            <img
              :if={@media[place.media_id]}
              src={~p"/media/#{place.media_id}"}
              alt={place.name}
              class="size-14 rounded-lg object-cover flex-shrink-0"
            />
            <div>
              <div class="font-semibold text-sm">{place.name}</div>
              <div class="text-xs opacity-60">{humanize_category(place.category)}</div>
              <.poet_pick :if={place.poet_rating} place={place} poet={@poet} />
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :place, :map, required: true
  attr :media, :map, default: nil
  attr :poet, :map, required: true

  defp place_card(assigns) do
    ~H"""
    <div id={"place-#{@place.id}"} class="card bg-base-200 border border-base-300 overflow-hidden">
      <img
        :if={@media}
        src={~p"/media/#{@place.media_id}"}
        alt={@media.alt_text || @place.name}
        class="h-36 w-full object-cover"
      />
      <div class="card-body p-4 gap-2">
        <div class="flex items-start justify-between gap-2">
          <h3 class="font-semibold leading-snug">{@place.name}</h3>
          <span class="badge badge-warning badge-sm whitespace-nowrap">
            {format_date(@place.entry_date)}
          </span>
        </div>

        <div class="text-xs opacity-60">{humanize_category(@place.category)}</div>
        <.poet_pick :if={@place.poet_rating} place={@place} poet={@poet} />

        <p :if={@place.blurb} class="text-sm opacity-80 leading-relaxed">{@place.blurb}</p>

        <div :if={@place.address} class="text-xs opacity-50">{@place.address}</div>

        <a
          :if={@place.source_url}
          href={@place.source_url}
          target="_blank"
          rel="noopener noreferrer nofollow"
          class="link link-primary text-sm"
        >
          View details ↗
        </a>
      </div>
    </div>
    """
  end

  # The rating is the poet's own opinion, and it has to say so. A bare star
  # next to a restaurant reads as a sourced review score, which is exactly what
  # this number is not.
  attr :place, :map, required: true
  attr :poet, :map, required: true

  defp poet_pick(assigns) do
    ~H"""
    <div
      class="text-xs flex items-center gap-1"
      data-testid="poet-pick"
      title={"#{@poet.name}'s own rating — not a review score"}
    >
      <span class="text-warning">{String.duplicate("★", @place.poet_rating)}</span>
      <span class="opacity-60">{@poet.name}'s pick</span>
    </div>
    """
  end

  defp humanize_category(category), do: String.capitalize(category)

  defp unmapped_note(1), do: "One place couldn't be put on the map — it's still in the list."

  defp unmapped_note(n),
    do: "#{n} places couldn't be put on the map — they're still in the list."

  defp format_date(%Date{} = date), do: Calendar.strftime(date, "%b %-d")
  defp format_date(_), do: ""
end
