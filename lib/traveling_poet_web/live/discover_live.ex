defmodule TravelingPoetWeb.DiscoverLive do
  @moduledoc """
  `/discover`: everything the poets have found, for anyone, signed in or not.

  One map with three layers (where each poet is now, the pages they wrote,
  the places they found) and a tour that turns through the newest pages,
  one poet at a time (`Discover.rotation/1`). A click on anything opens its
  overview beside the map, with the way into it.

  The map hook (`DiscoverMap`) drives the tour and reports what is shown
  with a `select` event; the overview is rendered here, so every word and
  drawing on it goes through the same components as the journal and the
  guide. The map div is `phx-update="ignore"`, so a publish anywhere in the
  fleet reaches it as a `discover:update` push, never as a new attribute.

  The hook asks for its data once it is connected (`load`, and `load_village`
  only when someone opens the village) rather than reading it from a page
  attribute: in an attribute it was HTML-escaped and sent twice, in the page
  and again over the socket, about 480 KB per visit before this changed.

  The same LiveView is embedded, compact, where the fleet used to have its
  own views: on the home page (`live_render` from the controller template)
  and on a new reader's journal while their first entry is being written.
  Its session says how:

    * `"compact" => true`: no page chrome and no layer toggles, a smaller
      map, and a link to the full page.
    * `"me_poet_id" => id`: the reader's own poet, not yet on the road, as a
      red ring where it sets out from. It is the reader's own, so it is
      shown exactly; nobody else sees it.
  """

  use TravelingPoetWeb, :live_view

  import TravelingPoetWeb.NotebookComponents, only: [section: 1]
  import TravelingPoetWeb.GuideComponents, only: [place_card: 1]

  alias TravelingPoet.{Discover, Poets}
  alias TravelingPoet.Guide.PlaceTopics

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "journal:published")
    end

    compact = session["compact"] == true

    socket =
      socket
      |> assign(:compact, compact)
      # Embedded, the host page names the tab; a compact view on the home
      # page otherwise retitled it "Discover".
      |> then(&if(compact, do: &1, else: assign(&1, :page_title, "Discover")))
      |> assign(:me, me(session["me_poet_id"]))
      |> assign_discover()

    {:ok, assign(socket, :selected, first_selection(socket.assigns.discover))}
  end

  defp assign_discover(socket),
    do: assign(socket, :discover, Map.put(Discover.build(), :me, socket.assigns.me))

  defp me(id) when is_integer(id) do
    case Poets.get_poet(id) do
      %{current_lat: lat, current_lng: lng} = poet when is_number(lat) and is_number(lng) ->
        %{lat: lat, lng: lng, name: poet.current_place_name, poet: poet.name}

      _ ->
        nil
    end
  end

  defp me(_), do: nil

  @impl true
  def handle_event("select", %{"kind" => kind, "id" => id} = params, socket) do
    case load(kind, id) do
      nil ->
        {:noreply, socket}

      selected ->
        socket = assign(socket, :selected, selected)

        # The map picked it and already shows it; a link in the overview
        # did not, so the map is told where to look.
        if params["from"] == "map",
          do: {:noreply, socket},
          else: {:noreply, push_event(socket, "discover:focus", %{kind: kind, id: id})}
    end
  end

  def handle_event("select", _params, socket), do: {:noreply, socket}

  # The hook's data, asked for once it is connected. See the moduledoc.
  def handle_event("load", _params, socket),
    do: {:reply, Discover.client_payload(socket.assigns.discover), socket}

  def handle_event("load_village", _params, socket),
    do: {:reply, Discover.village(), socket}

  # A subject under a place: open the village there.
  def handle_event("village", %{"topic" => topic}, socket) do
    if PlaceTopics.valid?(topic),
      do: {:noreply, push_event(socket, "discover:village", %{topic: topic})},
      else: {:noreply, socket}
  end

  @impl true
  def handle_info({:journal_published, _poet_id, _entry_id}, socket) do
    socket = assign_discover(socket)

    {:noreply,
     push_event(socket, "discover:update", Discover.client_payload(socket.assigns.discover))}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # The page opens on the tour's first page, so the dead render (and a
  # reader without JavaScript) already shows something worth reading.
  defp first_selection(%{rotation: [id | _]}), do: load("entry", id)
  defp first_selection(_), do: nil

  defp load("entry", id), do: tag(:entry, Discover.entry(id))

  defp load("place", id) do
    case Discover.place(id) do
      nil ->
        nil

      overview ->
        topics =
          [overview.place.topic, overview.place.second_topic]
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&{&1, PlaceTopics.names(&1)})
          |> Enum.reject(fn {_path, names} -> is_nil(names) end)

        tag(:place, Map.put(overview, :topics, topics))
    end
  end

  defp load("poet", slug) when is_binary(slug), do: tag(:poet, Discover.poet(slug))
  defp load(_, _), do: nil

  defp tag(_kind, nil), do: nil
  defp tag(kind, overview), do: Map.put(overview, :kind, kind)

  @impl true
  def render(%{compact: true} = assigns) do
    ~H"""
    <div class="discover-compact" id="discover-compact">
      <.discover_view discover={@discover} selected={@selected} compact me={@me} />
      <p class="discover-more">
        <a href={~p"/discover"} class="link" data-track="discover-more">
          Everything the poets have found, in Discover &rarr;
        </a>
      </p>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active_tab={:discover}>
      <div class="discover-head">
        <h1 class="text-2xl font-bold">Discover</h1>
        <.totals discover={@discover} />
      </div>

      <%!-- The hook owns aria-pressed from here on: without ignore, every
            re-render put it back to "true" while the layer stayed hidden. --%>
      <div
        class="discover-layers"
        role="group"
        aria-label="Show on the map"
        id="discover-layers"
        phx-update="ignore"
      >
        <button
          :for={{layer, label} <- [poets: "Poets", entries: "Pages", places: "Places"]}
          type="button"
          class="spread-chip discover-layer"
          data-layer={layer}
          aria-pressed="true"
        >
          <span class={"discover-swatch discover-swatch-#{layer}"} aria-hidden="true"></span>
          {label}
        </button>
      </div>

      <.discover_view discover={@discover} selected={@selected} />
    </Layouts.app>
    """
  end

  attr :discover, :map, required: true

  defp totals(assigns) do
    ~H"""
    <p class="text-sm opacity-70" id="discover-totals">
      {@discover.totals.poets} {ngettext("poet", "poets", @discover.totals.poets)} on the road, {@discover.totals.entries} {ngettext(
        "page",
        "pages",
        @discover.totals.entries
      )} written, {@discover.totals.places} {ngettext(
        "place",
        "places",
        @discover.totals.places
      )} found.
    </p>
    """
  end

  attr :discover, :map, required: true
  attr :selected, :map, default: nil
  attr :compact, :boolean, default: false
  attr :me, :map, default: nil

  defp discover_view(assigns) do
    ~H"""
    <.totals :if={@compact and @discover.totals.poets > 0} discover={@discover} />
    <%!-- The hook owns aria-pressed, as with the layer toggles. --%>
    <div
      id="discover-views"
      class="discover-views"
      role="group"
      aria-label="How to look"
      phx-update="ignore"
    >
      <button type="button" data-view="world" aria-pressed="true">
        <.icon name="hero-globe-europe-africa" class="size-4" /> World
      </button>
      <button type="button" data-view="village" aria-pressed="false">
        <.icon name="hero-squares-2x2" class="size-4" /> Village
      </button>
    </div>
    <div class={["discover-grid", @compact && "mt-3"]}>
      <div
        id="discover-map"
        phx-hook="DiscoverMap"
        phx-update="ignore"
        data-panel="discover-panel"
        data-layers={!@compact && "discover-layers"}
        data-views="discover-views"
        data-url={!@compact && "true"}
        class="discover-map rounded-2xl overflow-hidden border border-base-300 z-0"
      >
      </div>

      <aside id="discover-panel" class="discover-panel" aria-live="polite">
        <.overview :if={@selected} selected={@selected} />
        <p :if={is_nil(@selected) and @me} class="text-sm opacity-60 p-4">
          Here is where {@me.poet} sets out from. Yours will be the first poet on the road.
        </p>
        <p :if={is_nil(@selected) and is_nil(@me)} class="text-sm opacity-60 p-4">
          No poets on the road yet. The first ones are still lacing their boots.
        </p>
        <div :if={@discover.rotation != []} class="discover-tour-nav">
          <button type="button" class="btn btn-ghost btn-sm" data-discover-prev>
            <.icon name="hero-chevron-left" class="size-4" /> Previous page
          </button>
          <button type="button" class="btn btn-ghost btn-sm" data-discover-next>
            Next page <.icon name="hero-chevron-right" class="size-4" />
          </button>
        </div>
      </aside>
    </div>
    <p :if={@discover.anonymous != []} class="text-xs opacity-50 mt-2">
      Grey dots are poets whose journals are private.
    </p>
    """
  end

  attr :selected, :map, required: true

  defp overview(%{selected: %{kind: :entry}} = assigns) do
    ~H"""
    <article class="notebook-page discover-card" id={"discover-entry-#{@selected.entry.id}"}>
      <.byline poet={@selected.poet}>
        {entry_when(@selected.entry)}
      </.byline>
      <h2 class="discover-title">{@selected.entry.title}</h2>
      <.section :if={@selected.drawing} section={%{kind: "illustration"}} media={@selected.drawing} />
      <p :if={@selected.entry.teaser} class="discover-teaser">{@selected.entry.teaser}</p>
      <div class="discover-links">
        <a
          href={~p"/p/#{@selected.poet.slug}/#{Date.to_iso8601(@selected.entry.entry_date)}"}
          class="link"
        >
          Read this page
        </a>
        <button
          type="button"
          class="link"
          phx-click="select"
          phx-value-kind="poet"
          phx-value-id={@selected.poet.slug}
        >
          More about {@selected.poet.name}
        </button>
      </div>
    </article>
    """
  end

  defp overview(%{selected: %{kind: :place}} = assigns) do
    ~H"""
    <div class="discover-card" id={"discover-place-#{@selected.place.id}"}>
      <.byline poet={@selected.poet}>recommends</.byline>
      <.place_card
        place={@selected.place}
        media={@selected.drawing_from == :place && @selected.drawing}
        poet={@selected.poet}
      />
      <div :if={@selected.drawing_from == :entry} class="discover-borrowed">
        <.section section={%{kind: "illustration"}} media={@selected.drawing} />
        <p class="text-xs opacity-60">From the page {@selected.poet.name} wrote there</p>
      </div>
      <p :if={@selected.also != []} class="discover-also">
        Also found by {Enum.map_join(@selected.also, ", ", & &1.name)}
      </p>
      <div :if={@selected.topics != []} class="discover-subjects" aria-label="Subjects">
        <button
          :for={{path, names} <- @selected.topics}
          type="button"
          class="discover-subject"
          phx-click="village"
          phx-value-topic={path}
          title="See this subject in the village"
        >
          {Enum.join(names, " › ")}
        </button>
      </div>
      <div class="discover-links">
        <a
          href={
            ~p"/p/#{@selected.poet.slug}/guide?#{[view: "map", stay: @selected.place.path_point_id, place: @selected.place.id] |> Enum.reject(fn {_k, v} -> is_nil(v) end)}"
          }
          class="link"
        >
          Open in {@selected.poet.name}&rsquo;s guide
        </a>
        <a
          href={~p"/p/#{@selected.poet.slug}/#{Date.to_iso8601(@selected.place.entry_date)}"}
          class="link"
        >
          Read the page it came from
        </a>
      </div>
    </div>
    """
  end

  defp overview(%{selected: %{kind: :poet}} = assigns) do
    ~H"""
    <div class="notebook-page discover-card" id={"discover-poet-#{@selected.poet.slug}"}>
      <.byline poet={@selected.poet}>now in {@selected.poet.current_place_name}</.byline>
      <p :if={@selected.latest} class="discover-teaser">
        Latest page:
        <a
          href={~p"/p/#{@selected.poet.slug}/#{Date.to_iso8601(@selected.latest.entry_date)}"}
          class="link"
        >
          {@selected.latest.title}
        </a>
      </p>
      <div class="tour-stats">
        <div class="tour-stat">
          <b>{@selected.stats.days}</b>
          <span>{ngettext("day", "days", @selected.stats.days)} on the road</span>
        </div>
        <div class="tour-stat">
          <b>{@selected.stats.entries}</b>
          <span>{ngettext("page", "pages", @selected.stats.entries)}</span>
        </div>
        <div class="tour-stat">
          <b>{@selected.stats.places}</b>
          <span>{ngettext("place", "places", @selected.stats.places)}</span>
        </div>
      </div>
      <div class="discover-links">
        <a href={~p"/p/#{@selected.poet.slug}"} class="link">Open {@selected.poet.name}&rsquo;s journal</a>
        <a href={~p"/p/#{@selected.poet.slug}/guide"} class="link">
          {@selected.poet.name}&rsquo;s guide
        </a>
      </div>
    </div>
    """
  end

  defp entry_when(%{entry_date: date, place_name: place}) do
    day = Calendar.strftime(date, "%B %-d")
    if place in [nil, ""], do: day, else: "#{day}, #{place}"
  end

  attr :poet, :map, required: true
  slot :inner_block, required: true

  defp byline(assigns) do
    ~H"""
    <div class="discover-byline">
      <img :if={@poet.avatar_url} src={@poet.avatar_url} alt="" class="discover-avatar" />
      <span :if={!@poet.avatar_url} class="discover-avatar spread-chip-initial">
        {String.first(@poet.name)}
      </span>
      <span>
        <b>{@poet.name}</b>
        <small>{render_slot(@inner_block)}</small>
      </span>
    </div>
    """
  end
end
