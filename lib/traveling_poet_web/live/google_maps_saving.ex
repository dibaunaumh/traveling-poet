defmodule TravelingPoetWeb.GoogleMapsSaving do
  @moduledoc """
  The LiveView half of "Save to Google Maps" (dec-012), shared by the
  owner's guide, public guides and a shared Saved list. Each calls
  `assign_ids/1` once `@places` is set and routes `handle_async(:google_ids,
  ...)` here.

  `@google_ids` is what the cache already knows, so the buttons render at
  once for places seen before; the rest are looked up in the background
  (`GooglePlaces.resolve/1`) and `@google_pending` covers the wait.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, start_async: 3]

  alias TravelingPoet.GooglePlaces

  def assign_ids(socket) do
    places = socket.assigns.places

    lookup? =
      connected?(socket) and GooglePlaces.enabled?() and GooglePlaces.missing(places) != []

    socket =
      socket
      |> assign(:google_ids, GooglePlaces.cached(places))
      |> assign(:google_pending, lookup?)

    if lookup?,
      do: start_async(socket, :google_ids, fn -> GooglePlaces.resolve(places) end),
      else: socket
  end

  def handle_async({:ok, ids}, socket) do
    {:noreply,
     socket
     |> assign(:google_ids, Map.merge(socket.assigns.google_ids, ids))
     |> assign(:google_pending, false)}
  end

  def handle_async({:exit, _reason}, socket),
    do: {:noreply, assign(socket, :google_pending, false)}
end
