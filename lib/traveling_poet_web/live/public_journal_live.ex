defmodule TravelingPoetWeb.PublicJournalLive do
  use TravelingPoetWeb, :live_view

  import TravelingPoetWeb.NotebookComponents
  import TravelingPoetWeb.RouteComponents

  alias TravelingPoet.{Guide, Journal, Poets, Topics}
  alias TravelingPoet.Journal.{EntryBundle, Spreads}

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Poets.get_public_poet_by_slug(slug) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "That journal doesn't exist or isn't public.")
         |> push_navigate(to: ~p"/")}

      poet ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "poet:#{poet.id}")
        end

        {:ok,
         socket
         |> assign(:poet, poet)
         |> assign(:page_title, "#{poet.name} — Traveling Poet")
         |> assign_journal(poet, nil)}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns[:poet] do
      nil ->
        {:noreply, socket}

      poet ->
        date =
          with %{"date" => date_str} <- params,
               {:ok, date} <- Date.from_iso8601(date_str) do
            date
          else
            _ -> nil
          end

        socket =
          if same_entry?(socket, date),
            do: socket,
            else: assign_journal(socket, poet, date)

        {:noreply, socket |> assign_spread(params["spread"]) |> push_map()}
    end
  end

  defp same_entry?(%{assigns: %{entry: %{entry_date: shown}}}, %Date{} = date), do: shown == date
  defp same_entry?(_socket, _date), do: false

  defp assign_spread(socket, requested) do
    requested = requested || (socket.assigns[:spread] && socket.assigns.spread.key)
    assign(socket, :spread, Spreads.pick(socket.assigns.spreads, requested))
  end

  defp spread_path(poet, entry, key),
    do: ~p"/p/#{poet.slug}/#{Date.to_iso8601(entry.entry_date)}?spread=#{key}"

  # The map div is phx-update="ignore" (Leaflet owns its DOM), so a changed
  # data-points attribute does NOT re-render it. Paging between entries has to
  # tell the hook directly or the map silently keeps the previous day's view.
  defp push_map(socket) do
    if connected?(socket) do
      push_event(
        socket,
        "map:update",
        map_points(
          socket.assigns.path_points,
          socket.assigns.poet,
          socket.assigns.entry,
          map_places(socket)
        )
      )
    else
      socket
    end
  end

  @impl true
  def handle_event("react", %{"kind" => kind}, socket) do
    user = socket.assigns[:current_user]
    entry = socket.assigns.entry

    if user && entry do
      Journal.toggle_reaction(entry.id, user.id, kind, "public")
      {:noreply, assign(socket, :public_reactions, public_reaction_counts(entry.id))}
    else
      {:noreply, put_flash(socket, :error, "Sign in to react.")}
    end
  end

  @impl true
  def handle_info({:journal_published, _entry_id}, socket) do
    poet = Poets.get_poet(socket.assigns.poet.id)
    {:noreply, socket |> assign(:poet, poet) |> assign_journal(poet, nil)}
  end

  # The poet revised an entry after feedback: reload whatever is on screen.
  @impl true
  def handle_info({:journal_revised, _entry_id}, socket) do
    poet = Poets.get_poet(socket.assigns.poet.id)
    date = socket.assigns.entry && socket.assigns.entry.entry_date
    {:noreply, socket |> assign(:poet, poet) |> assign_journal(poet, date)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp assign_journal(socket, poet, date) do
    entries = Journal.list_entries(poet.id, status: "published")

    entry =
      cond do
        date -> published_entry(poet, date)
        entries != [] -> Journal.preload_entry(hd(entries))
        true -> nil
      end

    journey_start = Journal.first_published_date(poet.id)
    bundle = EntryBundle.load(entry)
    entry = bundle.entry

    socket
    |> assign(:entries, entries)
    |> assign(:entry, entry)
    |> assign(:journey_start, journey_start)
    |> assign(:og, open_graph(poet, entry, journey_start))
    |> assign(:entry_media, bundle.media)
    |> assign(:extra_media, bundle.extra_media)
    |> assign(:places, bundle.places)
    |> assign(:place_media, bundle.place_media)
    |> assign(:find_media, bundle.find_media)
    |> assign(:spot_media, bundle.spot_media)
    |> assign_stay(poet, bundle.stay_id)
    |> assign_route(poet, entry)
    |> assign(:spreads, bundle.spreads)
    |> assign_spread(nil)
    |> assign(:public_reactions, entry && public_reaction_counts(entry.id))
    |> assign(:path_points, Poets.list_path_points(poet.id))
  end

  defp assign_stay(socket, _poet, nil), do: assign(socket, stay_id: nil, stay_count: 0)

  defp assign_stay(socket, poet, stay_id) do
    count = poet.id |> Guide.list_places(path_point_id: stay_id) |> length()
    assign(socket, stay_id: stay_id, stay_count: count)
  end

  defp guide_url(poet, nil), do: ~p"/p/#{poet.slug}/guide"

  defp guide_url(poet, stay_id),
    do: ~p"/p/#{poet.slug}/guide?#{[stay: stay_id, view: "itinerary"]}"

  defp map_places(%{assigns: %{spread: %{key: "places"}, places: places}}), do: places
  defp map_places(_socket), do: []

  defp places_spread?(%{spread: %{key: "places"}}), do: true
  defp places_spread?(_assigns), do: false

  defp finds_spread?(%{spread: %{key: "finds"}}), do: true
  defp finds_spread?(_assigns), do: false

  # No coordinates to pin on an excursion: the journey is drawn instead.
  defp assign_route(socket, poet, entry) do
    case entry && Topics.excursion_of(entry) do
      %{topic_id: id} = excursion when is_integer(id) ->
        assign(socket, :route, Topics.journey_diagram(poet.id, excursion))

      _ ->
        assign(socket, :route, nil)
    end
  end

  # Link previews for a shared public entry: the day and title, the poet's
  # teaser, and the drawing. Only public poets reach this view, and their
  # /media/:id is world-readable, so the image URL resolves for crawlers.
  defp open_graph(_poet, nil, _start), do: nil

  defp open_graph(poet, entry, journey_start) do
    base = Application.get_env(:traveling_poet, :phoenix_url, "")
    drawing = Journal.entry_illustration(entry)

    %{
      title: "Day #{Journal.journey_day(entry, journey_start)}: #{entry_title(entry)}",
      description:
        entry.teaser ||
          "#{poet.name}'s journal from #{entry.place_name || excursion_label(entry) || "the road"}",
      image: drawing && "#{base}/media/#{drawing.id}",
      url: "#{base}/p/#{poet.slug}/#{entry.entry_date}"
    }
  end

  defp published_entry(poet, date) do
    case Journal.get_entry_preloaded(poet.id, date) do
      %{status: "published"} = entry -> entry
      _ -> nil
    end
  end

  defp public_reaction_counts(entry_id) do
    Journal.list_reactions(entry_id, "public")
    |> Enum.frequencies_by(& &1.kind)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={assigns[:current_user]}
      credits_low={assigns[:credits_low]}
    >
      <div class="journal-column mx-auto max-w-5xl">
        <div class="flex items-center gap-3 mb-3">
          <img
            :if={@poet.avatar_url}
            src={@poet.avatar_url}
            class="w-12 h-12 rounded-full object-cover"
            alt={@poet.name}
          />
          <div>
            <h1 class="text-xl font-semibold">{@poet.name}</h1>
            <p class="text-sm opacity-70">
              a traveling poet
              <span :if={@poet.current_place_name}>· 📍 {@poet.current_place_name}</span>
            </p>
          </div>
        </div>

        <.excursion_route
          :if={not is_nil(@route) and !finds_spread?(assigns)}
          diagram={@route}
          title={"#{@poet.name}'s journey through this topic"}
        />

        <div
          :if={!places_spread?(assigns) and is_nil(@route)}
          id="public-poet-map"
          phx-hook="PoetMap"
          phx-update="ignore"
          class="w-full h-56 rounded-xl border border-base-300 z-0"
          data-points={Jason.encode!(map_points(@path_points, @poet, @entry, []))}
        >
        </div>

        <div :if={@entry} class="spread-wrap">
          <.spread_tabs
            spreads={@spreads}
            active={@spread.key}
            patch={&spread_path(@poet, @entry, &1)}
          />
          <.places_spread
            :if={places_spread?(assigns)}
            id={"places-#{@entry.id}"}
            entry={@entry}
            day={Journal.journey_day(@entry, @journey_start)}
            spread={@spread}
            poet={@poet}
            place_media={@place_media}
            guide_url={guide_url(@poet, @stay_id)}
            stay_count={@stay_count}
          >
            <:map>
              <div
                id="public-poet-map"
                phx-hook="PoetMap"
                phx-update="ignore"
                class="taped-map-canvas z-0"
                data-points={Jason.encode!(map_points(@path_points, @poet, @entry, @places))}
              >
              </div>
            </:map>
            <:controls>
              <.link
                :for={{label, date} <- entry_nav(@entries, @entry)}
                navigate={~p"/p/#{@poet.slug}/#{date}"}
                class="btn btn-ghost btn-xs"
              >
                {label}
              </.link>
            </:controls>
          </.places_spread>
          <.finds_spread
            :if={finds_spread?(assigns)}
            id={"finds-#{@entry.id}"}
            entry={@entry}
            day={Journal.journey_day(@entry, @journey_start)}
            spread={@spread}
            poet={@poet}
            find_media={@find_media}
          >
            <:controls>
              <.link
                :for={{label, date} <- entry_nav(@entries, @entry)}
                navigate={~p"/p/#{@poet.slug}/#{date}"}
                class="btn btn-ghost btn-xs"
              >
                {label}
              </.link>
            </:controls>
          </.finds_spread>
          <.entry_spread
            :if={!places_spread?(assigns) and !finds_spread?(assigns)}
            id={"entry-#{@entry.id}"}
            entry={@entry}
            day={Journal.journey_day(@entry, @journey_start)}
            spread={@spread}
            media={@entry_media}
            place_links={
              place_links(@places, ~p"/p/#{@poet.slug}/#{Date.to_iso8601(@entry.entry_date)}")
            }
            spot_media={@spot_media}
          >
            <:controls>
              <.link
                :for={{label, date} <- entry_nav(@entries, @entry)}
                navigate={~p"/p/#{@poet.slug}/#{date}"}
                class="btn btn-ghost btn-xs"
              >
                {label}
              </.link>
            </:controls>
            <:right_footer>
              <div class="flex items-center gap-2 border-t border-base-300 pt-3 mt-4">
                <button
                  :for={{kind, emoji} <- reaction_kinds()}
                  phx-click="react"
                  phx-value-kind={kind}
                  class="btn btn-ghost btn-sm"
                >
                  {emoji}
                  <span :if={@public_reactions[kind]} class="text-xs">{@public_reactions[kind]}</span>
                </button>
              </div>
            </:right_footer>
          </.entry_spread>
        </div>

        <div :if={is_nil(@entry)} class="mt-10 text-center opacity-70">
          <p>No published entries yet — check back soon.</p>
        </div>

        <%!-- A public journal is published writing, some of it a model's. A
              reader who finds something that should not be here needs a way
              to say so from the page itself. --%>
        <p class="mt-8 text-center text-xs opacity-50">
          <a href={report_mailto(@poet, @entry)} id="report-journal" class="link">
            Report this journal
          </a>
        </p>
      </div>
    </Layouts.app>
    """
  end

  defp reaction_kinds do
    [{"love", "❤️"}, {"inspiring", "✨"}, {"want_more", "➕"}]
  end

  # `entry` focuses the map on the day you are actually reading. Without it the
  # map only ever knew the poet's path and where it is NOW, so paging back
  # through the journal left it sitting on the current city while the page
  # talked about somewhere else entirely.
  defp map_points(path_points, poet, entry, places) do
    points = Enum.map(path_points, fn p -> %{lat: p.lat, lng: p.lng, name: p.place_name} end)

    current =
      if poet.current_lat do
        %{lat: poet.current_lat, lng: poet.current_lng, name: poet.current_place_name}
      end

    planned =
      if TravelingPoet.Poets.Poet.mode(poet) == "scout" do
        Poets.list_stops(poet.id)
        |> Enum.filter(&is_nil(&1.visited_at))
        |> Enum.map(fn s -> %{lat: s.lat, lng: s.lng, name: s.place_name} end)
      else
        []
      end

    %{
      path: points,
      current: current,
      planned: planned,
      poet: poet.name,
      focus: focus_point(entry),
      places: Guide.map_payload(places, poet.name)
    }
  end

  defp focus_point(%{lat: lat, lng: lng} = entry) when is_number(lat) and is_number(lng) do
    %{lat: lat, lng: lng, name: entry.place_name, date: Date.to_iso8601(entry.entry_date)}
  end

  defp focus_point(_), do: nil

  @report_to "dibaunaumh@gmail.com"

  # The page being reported travels in the subject, so a report needs no
  # explaining to be actionable.
  defp report_mailto(poet, entry) do
    page =
      if entry,
        do: url(~p"/p/#{poet.slug}/#{Date.to_iso8601(entry.entry_date)}"),
        else: url(~p"/p/#{poet.slug}")

    "mailto:#{@report_to}?" <> URI.encode_query(%{"subject" => "Report: #{page}"}, :rfc3986)
  end
end
