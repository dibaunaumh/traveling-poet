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

  import TravelingPoetWeb.GuideComponents

  alias TravelingPoetWeb.GuideState

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    poet = user.onboarding_completed && TravelingPoet.Poets.get_poet_by_user(user.id)

    if poet do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "poet:#{poet.id}")
      end

      {:ok, assign(socket, poet: poet, selected: nil, page_title: "Trip guide")}
    else
      {:ok, push_navigate(socket, to: ~p"/onboarding")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket),
    do: {:noreply, GuideState.apply_params(socket, params)}

  @impl true
  def handle_event("set_view", %{"view" => view}, socket),
    do: {:noreply, push_patch(socket, to: guide_path(socket, view: view))}

  def handle_event("set_filter", %{"filter" => filter}, socket),
    do: {:noreply, push_patch(socket, to: guide_path(socket, filter: filter))}

  def handle_event("set_stay", %{"stay" => stay}, socket),
    do: {:noreply, push_patch(socket, to: guide_path(socket, stay: stay))}

  # The map pushes a selection back up so the detail card renders server-side.
  def handle_event("select_place", %{"id" => id}, socket),
    do: {:noreply, GuideState.select_place(socket, id)}

  @impl true
  def handle_info({:guide_geocoded, _poet_id}, socket), do: {:noreply, reload(socket)}
  def handle_info({:journal_published, _id}, socket), do: {:noreply, reload(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp reload(socket), do: socket |> GuideState.assign_places() |> GuideState.push_map()

  defp guide_path(socket, overrides), do: ~p"/guide?#{GuideState.query(socket, overrides)}"

  ## Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active_tab={:guide}>
      <.guide_header poet={@poet} stay={@stay} view={@view} />
      <.filter_chips filter={@filter} counts={@counts} />
      <.stay_switcher stays={@stays} stay={@stay} />

      <.empty_state :if={@places == []} poet={@poet} />

      <div :if={@places != []}>
        <.map_view
          :if={@view == "map"}
          map_places={@map_places}
          selected={@selected}
          media={@media}
          poet={@poet}
          unmapped={@unmapped}
        />
        <.list_view :if={@view == "list"} places={@places} media={@media} poet={@poet} />
        <.itinerary_view
          :if={@view == "itinerary"}
          days={@days}
          media={@media}
          poet={@poet}
          stay={@stay}
        />
      </div>
    </Layouts.app>
    """
  end
end
