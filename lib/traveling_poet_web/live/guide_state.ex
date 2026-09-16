defmodule TravelingPoetWeb.GuideState do
  @moduledoc """
  The trip guide's state, shared by the owner's `/guide` and the public
  `/p/:slug/guide`.

  Both views read the same data, honour the same query params and answer the
  same events; they differ only in how they resolve the poet and where they
  push_patch to. Keeping this out of the LiveViews is what stops the two
  drifting apart -- and a drift here would mean the public guide quietly
  showing something the owner's does not.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  alias TravelingPoet.{Guide, Journal, Poets, Topics}
  alias TravelingPoet.Guide.Place
  alias TravelingPoet.Topics.Find

  @views ~w(map list itinerary)
  # A topic's finds are links, not addresses: nothing to put on a map.
  @topic_views ~w(list itinerary)
  # List, not map, is the default: coordinates arrive asynchronously and are
  # allowed to fail, so list is the view that always has something in it.
  @default_view "list"

  def views, do: @views

  @doc """
  Applies view/filter/stay from the URL, then loads the places.

  Ends by pushing the pins to the map. That is not optional: the map div is
  `phx-update="ignore"` (Leaflet owns its DOM), so a changed `data-places`
  attribute does NOT re-render it. Without this push, switching city or filter
  while the map is open left the previous stay's pins sitting there -- the
  list and itinerary updated correctly and only the map lied.
  """
  def apply_params(socket, params) do
    socket = socket |> assign_journeys() |> assign_topic(params["topic"])

    {views, filters} =
      if socket.assigns.topic,
        do: {@topic_views, Find.filter_groups()},
        else: {@views, Guide.filter_groups()}

    socket
    |> assign(:view, param(params, "view", views, @default_view))
    |> assign(:filter, param(params, "filter", filters, "all"))
    |> assign_stay(params["stay"])
    |> assign(:excursion_param, params["excursion"])
    |> assign_places()
    |> push_map()
  end

  # Topics are the owner's: the LiveView opts in with `show_topics`. The
  # public guide never does, so a crafted ?topic= there is simply ignored and
  # a public page never lists what its poet's companion follows.
  defp assign_journeys(socket) do
    journeys =
      if socket.assigns[:show_topics],
        do: Topics.list_guide_topics(socket.assigns.poet.id),
        else: []

    assign(socket, :journeys, journeys)
  end

  defp assign_topic(socket, requested) do
    topic =
      Enum.find_value(socket.assigns.journeys, fn {t, _count} ->
        to_string(t.id) == requested && t
      end)

    assign(socket, :topic, topic)
  end

  # Whitelisted, never String.to_atom on user input.
  defp param(params, key, allowed, default) do
    case params[key] do
      value when is_binary(value) -> if value in allowed, do: value, else: default
      _ -> default
    end
  end

  defp assign_stay(socket, requested) do
    poet = socket.assigns.poet
    stays = Guide.list_stays(poet.id)

    stay =
      Enum.find(stays, fn s -> to_string(s.id) == requested end) || default_stay(stays, poet)

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

  @doc """
  Reloads the places for the current stay and filter.

  `published_only` is left at its default, so a draft entry's places are
  unreachable from BOTH views -- the owner does not get an early look at what
  the poet has not published yet, and the public view cannot leak one.
  """
  def assign_places(%{assigns: %{topic: %{} = _topic}} = socket), do: assign_finds(socket)

  def assign_places(socket) do
    %{poet: poet, stay: stay, filter: filter} = socket.assigns

    all =
      poet.id
      |> Guide.list_places(path_point_id: stay_id(stay))
      # Logged again on a later day before the poet knew better: shown once,
      # as first logged. The data keeps both; the guide lists the place once.
      |> Guide.dedupe_by_name()
      |> sort_ended_last()

    shown = if filter == "all", do: all, else: Enum.filter(all, &in_group?(&1, filter))

    socket
    |> assign(:counts, Guide.counts_by_group(all))
    |> assign(:places, shown)
    |> assign(:days, Guide.group_by_day(shown))
    |> assign(:map_places, Guide.map_payload(shown, poet.name))
    |> assign(:unmapped, Guide.unmapped_count(shown))
    |> assign(:media, media_for(shown))
    |> assign(:excursions, [])
    |> assign(:excursion, nil)
    |> assign(:finds, [])
    |> assign(:find_days, [])
    |> keep_selection()
  end

  @doc """
  A topic's side of the guide: its published excursions (the venue pills),
  the one picked or all of them, and their finds under the kind filter.
  Place assigns are emptied so the map hook is told there is nothing to pin.
  """
  def assign_finds(socket) do
    %{poet: poet, topic: topic, filter: filter} = socket.assigns
    excursions = Topics.list_published_excursions(poet.id, topic.id)

    excursion =
      Enum.find(excursions, &(to_string(&1.id) == socket.assigns[:excursion_param]))

    picked = if excursion, do: [excursion], else: excursions
    by_entry = picked |> Enum.map(& &1.journal_entry_id) |> Topics.list_finds_for_entries()
    all = Enum.flat_map(picked, &Map.get(by_entry, &1.journal_entry_id, []))

    shown =
      if filter == "all", do: all, else: Enum.filter(all, &(Find.group_for(&1.kind) == filter))

    socket
    |> assign(:excursions, excursions)
    |> assign(:excursion, excursion)
    |> assign(:finds, shown)
    |> assign(:find_days, find_days(picked, shown))
    |> assign(:counts, find_counts(all))
    |> assign(:media, media_for(shown))
    |> assign(:places, [])
    |> assign(:days, [])
    |> assign(:map_places, [])
    |> assign(:unmapped, 0)
    |> assign(:selected, nil)
  end

  # One stop per excursion, numbered in the order they happened, each with
  # the finds that survived the filter. An excursion the filter emptied
  # stays, so "Excursion 2" never becomes "Excursion 1" under a chip.
  defp find_days(excursions, finds) do
    by_entry = Enum.group_by(finds, & &1.journal_entry_id)

    excursions
    |> Enum.with_index(1)
    |> Enum.map(fn {x, n} ->
      %{n: n, excursion: x, finds: Map.get(by_entry, x.journal_entry_id, [])}
    end)
  end

  defp find_counts(finds) do
    finds
    |> Enum.frequencies_by(&Find.group_for(&1.kind))
    |> Map.put("all", length(finds))
  end

  # An events tab whose first cards are exhibitions that closed weeks ago is
  # worse than an empty one. They stay visible -- the poet did write about
  # them, and hiding them silently would be its own small lie -- but they sink
  # below everything a reader could still act on.
  defp sort_ended_last(places) do
    today = Date.utc_today()
    Enum.sort_by(places, &Place.ended?(&1, today))
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

  # A selected pin that the new filter excludes must not keep its detail card
  # open beside a map that no longer shows it.
  defp keep_selection(socket) do
    selected = socket.assigns[:selected]
    still_shown = selected && Enum.find(socket.assigns.places, &(&1.id == selected.id))
    assign(socket, :selected, still_shown)
  end

  @doc "Selects a place by id, ignoring one that is not currently shown."
  def select_place(socket, id) do
    assign(socket, :selected, Enum.find(socket.assigns.places, &(&1.id == id)))
  end

  @doc """
  Pushes the current pins to the map hook.

  `phx-update="ignore"` means a changed data attribute never re-renders the
  map, so filter and geocode changes have to arrive as an event.
  """
  def push_map(socket) do
    # Only meaningful once the client is connected; on the dead render the
    # hook has not mounted and reads data-places itself.
    if Phoenix.LiveView.connected?(socket) do
      push_event(socket, "map:update", %{places: socket.assigns.map_places})
    else
      socket
    end
  end

  @doc "The query string shared by both guides' push_patch targets."
  def query(socket, overrides) do
    %{view: view, filter: filter, stay: stay} = socket.assigns
    topic = socket.assigns[:topic]
    excursion = socket.assigns[:excursion]

    %{
      "view" => view,
      "filter" => filter,
      "stay" => stay && to_string(stay.id),
      "topic" => topic && to_string(topic.id),
      "excursion" => excursion && to_string(excursion.id)
    }
    |> Map.merge(Map.new(overrides, fn {k, v} -> {to_string(k), to_string(v)} end))
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
  end
end
