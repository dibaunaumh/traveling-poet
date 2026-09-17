defmodule TravelingPoetWeb.GuideLive do
  @moduledoc """
  The trip guide: the concrete places the poet found, as map, list, and
  itinerary, and, for each of the companion's topics, what the poet brought
  back from its excursions (venues and finds, as list and itinerary).

  A separate LiveView rather than a tab inside JournalLive, which already
  carries the chat sidebar, uploads, keepalive timers and the provisioning
  state machine. Keeping the guide out of it also buys shareable URLs --
  view, filter and stay all live in the query string.
  """

  use TravelingPoetWeb, :live_view

  import TravelingPoetWeb.GuideComponents
  import TravelingPoetWeb.RouteComponents

  alias TravelingPoetWeb.GuideState

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    poet = user.onboarding_completed && TravelingPoet.Poets.get_poet_by_user(user.id)

    if poet do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "poet:#{poet.id}")
      end

      # Topics are the owner's own; the public guide leaves this off.
      {:ok,
       assign(socket, poet: poet, selected: nil, show_topics: true, page_title: "Trip guide")}
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

  # Switching journey starts the new one fresh: all its filters, all its
  # venues. A topic has no map, so a reader on the map lands on its route.
  def handle_event("set_journey", %{"topic" => topic}, socket) do
    view = if topic != "" and socket.assigns.view == "map", do: "route", else: socket.assigns.view
    overrides = [topic: topic, excursion: "", filter: "all", view: view]
    {:noreply, push_patch(socket, to: guide_path(socket, overrides))}
  end

  def handle_event("set_excursion", %{"excursion" => excursion}, socket),
    do: {:noreply, push_patch(socket, to: guide_path(socket, excursion: excursion))}

  # The map pushes a selection back up so the detail card renders server-side.
  def handle_event("select_place", %{"id" => id}, socket),
    do: {:noreply, GuideState.select_place(socket, id)}

  @impl true
  def handle_info({:guide_geocoded, _poet_id}, socket), do: {:noreply, reload(socket)}
  def handle_info({:journal_published, _id}, socket), do: {:noreply, reload(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp reload(socket), do: socket |> GuideState.assign_places() |> GuideState.push_map()

  defp guide_path(socket, overrides), do: ~p"/guide?#{GuideState.query(socket, overrides)}"

  defp finds_entry_path(%Date{} = date), do: ~p"/journal/#{Date.to_iso8601(date)}?spread=finds"

  ## Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active_tab={:guide}>
      <.guide_header poet={@poet} stay={@stay} view={@view} topic={@topic} />
      <.journey_switcher journeys={@journeys} topic={@topic} />

      <div :if={@topic}>
        <.filter_chips filter={@filter} counts={@counts} options={topic_filters()} />
        <.venue_switcher excursions={@excursions} excursion={@excursion} />

        <.excursion_route
          :if={@view == "route"}
          diagram={@route}
          title={"Every excursion into #{@topic.label}, and what it brought back"}
          empty={"No excursions into #{@topic.label} yet."}
        />

        <p
          :if={@finds == [] and @view == "list"}
          id="guide-finds-empty"
          class="text-sm opacity-60 py-10 text-center"
        >
          Nothing under this filter.
        </p>
        <.find_list_view
          :if={@view == "list" and @finds != []}
          finds={@finds}
          excursions={@excursions}
          media={@media}
          poet={@poet}
          entry_url={&finds_entry_path/1}
        />
        <.excursion_itinerary_view
          :if={@view == "itinerary"}
          find_days={@find_days}
          topic={@topic}
          media={@media}
          poet={@poet}
          entry_url={&finds_entry_path/1}
        />
      </div>

      <.filter_chips :if={is_nil(@topic)} filter={@filter} counts={@counts} />
      <.stay_switcher :if={is_nil(@topic)} stays={@stays} stay={@stay} />

      <.empty_state :if={is_nil(@topic) and @places == []} poet={@poet} />

      <div :if={is_nil(@topic) and @places != []}>
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
