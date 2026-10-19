defmodule TravelingPoetWeb.GuideLive do
  @moduledoc """
  The trip guide: the concrete places the poet found, as map, list, and
  itinerary, and, for each of the companion's topics, what the poet brought
  back from its excursions (destinations and finds, as list and itinerary).

  A separate LiveView rather than a tab inside JournalLive, which already
  carries the chat sidebar, uploads, keepalive timers and the provisioning
  state machine. Keeping the guide out of it also buys shareable URLs --
  view, filter and stay all live in the query string.
  """

  use TravelingPoetWeb, :live_view

  import TravelingPoetWeb.GuideComponents
  import TravelingPoetWeb.RouteComponents

  alias TravelingPoetWeb.{Bookmarking, GuideState}

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
       socket
       |> assign(
         poet: poet,
         selected: nil,
         show_topics: true,
         page_title: dgettext("guide", "Trip guide")
       )
       |> assign(:more_places, :idle)
       |> assign(saved_finds: [], saved_poets: %{}, saved_sources: %{})
       |> Bookmarking.assign_bookmarks()}
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
  # destinations. A topic has no map, so a reader on the map lands on its route.
  def handle_event("set_journey", %{"topic" => topic}, socket) do
    view = if topic != "" and socket.assigns.view == "map", do: "route", else: socket.assigns.view
    overrides = [topic: topic, excursion: "", filter: "all", view: view, saved: ""]
    {:noreply, push_patch(socket, to: guide_path(socket, overrides))}
  end

  def handle_event("set_saved", _params, socket) do
    view = if socket.assigns.view == "map", do: "map", else: "list"
    overrides = [saved: "1", topic: "", excursion: "", stay: "", filter: "all", view: view]
    {:noreply, push_patch(socket, to: guide_path(socket, overrides))}
  end

  def handle_event("share_saved", _params, socket) do
    {:ok, user} = TravelingPoet.Bookmarks.share(socket.assigns.current_user)
    {:noreply, assign(socket, :current_user, user)}
  end

  def handle_event("stop_sharing", _params, socket) do
    {:ok, user} = TravelingPoet.Bookmarks.stop_sharing(socket.assigns.current_user)
    {:noreply, assign(socket, :current_user, user)}
  end

  def handle_event("plan_days", %{"days" => days}, socket) do
    days =
      case Integer.parse(to_string(days)) do
        {n, _} -> n |> max(1) |> min(7)
        :error -> 3
      end

    {:noreply,
     socket |> assign(:plan_days, days) |> GuideState.apply_params(current_params(socket))}
  end

  # Saving here, or unsaving from the Saved view, which then drops the card.
  def handle_event("toggle_bookmark", params, socket) do
    {:noreply, socket} = Bookmarking.handle_event("toggle_bookmark", params, socket)
    {:noreply, socket |> GuideState.apply_params(current_params(socket))}
  end

  def handle_event("set_excursion", %{"excursion" => excursion}, socket),
    do: {:noreply, push_patch(socket, to: guide_path(socket, excursion: excursion))}

  # The map pushes a selection back up so the detail card renders server-side.
  # "More places" (card-121): the poet goes back out for a few more at this
  # stop, in a turn of its own; the places land through the usual geocoding
  # broadcast, the reply through {:more_places, ...} below.
  def handle_event("more_places", _params, socket) do
    %{current_user: user, poet: poet, stay: stay, more_places: state} = socket.assigns

    if state == :pending or is_nil(stay) do
      {:noreply, socket}
    else
      case TravelingPoet.Guide.MorePlaces.request(user, poet, stay) do
        {:ok, _entry} ->
          {:noreply, assign(socket, :more_places, :pending)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, more_places_refusal(reason, poet))}
      end
    end
  end

  def handle_event("select_place", %{"id" => id}, socket),
    do: {:noreply, GuideState.select_place(socket, id)}

  @impl true
  def handle_info({:guide_geocoded, _poet_id}, socket), do: {:noreply, reload(socket)}
  def handle_info({:journal_published, _id}, socket), do: {:noreply, reload(socket)}

  def handle_info({:more_places, _entry_id, result}, socket) do
    poet = socket.assigns.poet
    socket = socket |> assign(:more_places, :idle) |> reload()

    case result do
      {:ok, reply} when is_binary(reply) and reply != "" ->
        {:noreply,
         put_flash(
           socket,
           :info,
           dgettext("guide", "%{poet}: %{reply}", poet: poet.name, reply: first_line(reply))
         )}

      {:ok, _} ->
        {:noreply,
         put_flash(
           socket,
           :info,
           dgettext("guide", "%{poet} is done looking around.", poet: poet.name)
         )}

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           dgettext("guide", "%{poet} did not get back. Try again in a while.", poet: poet.name)
         )}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp more_places_refusal(:no_page, poet),
    do: dgettext("guide", "%{poet} has not written about this stop yet.", poet: poet.name)

  defp more_places_refusal(:credits, poet),
    do: dgettext("guide", "%{poet} is out of credits. Top up in Settings.", poet: poet.name)

  defp more_places_refusal(:cap, poet),
    do:
      dgettext("guide", "%{poet} is resting until tomorrow (daily limit reached).",
        poet: poet.name
      )

  defp more_places_refusal(:busy, poet),
    do:
      dgettext("guide", "%{poet} is in the middle of something. Try again in a few minutes.",
        poet: poet.name
      )

  defp first_line(reply) do
    reply
    |> String.split(~r/\r?\n/, trim: true)
    |> List.first("")
    |> String.slice(0, 240)
  end

  defp reload(socket), do: socket |> GuideState.assign_places() |> GuideState.push_map()

  defp guide_path(socket, overrides), do: ~p"/guide?#{GuideState.query(socket, overrides)}"

  defp current_params(socket), do: Map.new(GuideState.query(socket, []))

  defp finds_entry_path(%Date{} = date), do: ~p"/journal/#{Date.to_iso8601(date)}?spread=finds"

  ## Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active_tab={:guide}>
      <.guide_header poet={@poet} stay={@stay} view={@view} topic={@topic} saved={@saved_view} />
      <.journey_switcher
        journeys={@journeys}
        topic={@topic}
        saved_count={@saved_count}
        saved={@saved_view}
      />

      <div :if={@saved_view} id="guide-saved">
        <.filter_chips filter={@filter} counts={@counts} />
        <.share_saved :if={@places != []} token={@current_user.saved_share_token} />
        <.maps_export :if={@places != [] and !@native_app} kml_url={~p"/guide/saved.kml"} />
        <.day_plan :if={@day_plan != []} plan={@day_plan} days={@plan_days} />
        <p
          :if={@places == [] and @saved_finds == []}
          id="guide-saved-empty"
          class="text-sm opacity-60 py-10 text-center"
        >
          <span :if={@filter != "all"}>{dgettext("guide", "Nothing saved under this filter")}</span>
          <span :if={@filter == "all"}>
            {dgettext(
              "guide",
              "Nothing saved yet. Tap Save on a place or find, here, in any public guide, or in Discover."
            )}
          </span>
        </p>
        <.map_view
          :if={@view == "map" and @places != []}
          map_places={@map_places}
          selected={@selected}
          media={@media}
          poet={@poet}
          unmapped={@unmapped}
          bookmarks={@bookmarks}
          poets={@saved_poets}
          sources={@saved_sources}
          hint={dgettext("guide", "Pick a pin to see the place you saved.")}
        />
        <.list_view
          :if={@view == "list" and @places != []}
          places={@places}
          media={@media}
          poet={@poet}
          bookmarks={@bookmarks}
          poets={@saved_poets}
          sources={@saved_sources}
        />
        <div :if={@saved_finds != []} id="guide-saved-finds" class="mt-8">
          <h2 class="font-semibold mb-3">{dgettext("guide", "Finds you saved")}</h2>
          <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            <.find_card
              :for={find <- @saved_finds}
              find={find}
              media={@media[find.media_id]}
              poet={@saved_poets[find.poet_id] || @poet}
              saved={saved(@bookmarks, find)}
              source={@saved_sources[find.id]}
            />
          </div>
        </div>
      </div>

      <div :if={@topic}>
        <.filter_chips filter={@filter} counts={@counts} options={topic_filters()} />
        <.destination_switcher excursions={@excursions} excursion={@excursion} />

        <.excursion_route
          :if={@view == "route"}
          diagram={@route}
          title={
            dgettext("guide", "Every excursion into %{topic}, and what it brought back",
              topic: @topic.label
            )
          }
          empty={dgettext("guide", "No excursions into %{topic} yet.", topic: @topic.label)}
        />

        <p
          :if={@finds == [] and @view == "list"}
          id="guide-finds-empty"
          class="text-sm opacity-60 py-10 text-center"
        >
          {dgettext("guide", "Nothing under this filter.")}
        </p>
        <.find_list_view
          :if={@view == "list" and @finds != []}
          finds={@finds}
          excursions={@excursions}
          media={@media}
          poet={@poet}
          entry_url={&finds_entry_path/1}
          bookmarks={@bookmarks}
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

      <.filter_chips :if={is_nil(@topic) and not @saved_view} filter={@filter} counts={@counts} />
      <.stay_switcher :if={is_nil(@topic) and not @saved_view} stays={@stays} stay={@stay} />

      <.empty_state :if={is_nil(@topic) and not @saved_view and @places == []} poet={@poet} />

      <div :if={is_nil(@topic) and not @saved_view and @places != []}>
        <.map_view
          :if={@view == "map"}
          map_places={@map_places}
          selected={@selected}
          media={@media}
          poet={@poet}
          unmapped={@unmapped}
          bookmarks={@bookmarks}
        />
        <.list_view
          :if={@view == "list"}
          places={@places}
          media={@media}
          poet={@poet}
          bookmarks={@bookmarks}
        />
        <.itinerary_view
          :if={@view == "itinerary"}
          days={@days}
          media={@media}
          poet={@poet}
          stay={@stay}
        />
      </div>

      <%!-- "More places" (card-121): only where the poet can act, this stop's
            own pages; a topic's finds and the Saved view have no poet to send. --%>
      <div
        :if={is_nil(@topic) and not @saved_view and @stay}
        id="guide-more"
        class="mt-8 flex flex-wrap items-center gap-3 border-t border-base-200 pt-5"
      >
        <button
          id="guide-more-places"
          type="button"
          phx-click="more_places"
          disabled={@more_places == :pending}
          class="btn btn-outline btn-sm gap-1"
        >
          <.icon
            name={if @more_places == :pending, do: "hero-arrow-path", else: "hero-sparkles"}
            class={["size-4", @more_places == :pending && "motion-safe:animate-spin"]}
          />
          {if @more_places == :pending,
            do: dgettext("guide", "Asking %{poet}…", poet: @poet.name),
            else: dgettext("guide", "More places")}
        </button>
        <span class="text-sm opacity-60">
          <span :if={@more_places == :pending}>
            {dgettext(
              "guide",
              "%{poet} is looking around %{place}. New places land here in a minute or two.",
              poet: @poet.name,
              place: @stay.place_name
            )}
          </span>
          <span :if={@more_places != :pending}>
            {dgettext("guide", "%{poet} goes back out for a few more around %{place}.",
              poet: @poet.name,
              place: @stay.place_name
            )}
          </span>
        </span>
      </div>
    </Layouts.app>
    """
  end
end
