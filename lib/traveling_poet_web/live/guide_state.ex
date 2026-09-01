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

  alias TravelingPoet.{Guide, Journal, Poets}
  alias TravelingPoet.Guide.Place

  @views ~w(map list itinerary)
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
    socket
    |> assign(:view, param(params, "view", @views, @default_view))
    |> assign(:filter, param(params, "filter", Guide.filter_groups(), "all"))
    |> assign_stay(params["stay"])
    |> assign_places()
    |> push_map()
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
  def assign_places(socket) do
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
    |> keep_selection()
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

    %{"view" => view, "filter" => filter, "stay" => stay && to_string(stay.id)}
    |> Map.merge(Map.new(overrides, fn {k, v} -> {to_string(k), to_string(v)} end))
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
  end
end
