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

  import TravelingPoetWeb.GuideComponents,
    only: [place_card: 1, humanize_category: 1, save_button: 1, saved: 2]

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
      |> then(&if(compact, do: &1, else: assign(&1, :page_title, dgettext("guide", "Discover"))))
      |> assign(:me, me(session["me_poet_id"]))
      |> TravelingPoetWeb.Bookmarking.assign_bookmarks()
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

  def handle_event("toggle_bookmark", params, socket),
    do: TravelingPoetWeb.Bookmarking.handle_event("toggle_bookmark", params, socket)

  # The hook's data, asked for once it is connected. See the moduledoc.
  def handle_event("load", _params, socket),
    do: {:reply, Discover.client_payload(socket.assigns.discover), socket}

  def handle_event("load_village", _params, socket),
    do: {:reply, Discover.village(), socket}

  # A poet's route of one kind of thing, in the order they were found: the
  # map draws it.
  def handle_event("journey", %{"poet" => slug, "kind" => kind}, socket) do
    case Discover.journey(slug, kind) do
      nil -> {:noreply, socket}
      route -> {:noreply, push_event(socket, "discover:journey", route)}
    end
  end

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
          |> Enum.map(&{&1, PlaceTopics.labels(&1)})
          |> Enum.reject(fn {_path, names} -> is_nil(names) end)

        tag(:place, Map.put(overview, :topics, topics))
    end
  end

  defp load("find", id) do
    case Discover.find(id) do
      nil -> nil
      overview -> tag(:find, Map.put(overview, :topics, subjects(overview.find)))
    end
  end

  defp load("poet", slug) when is_binary(slug), do: tag(:poet, Discover.poet(slug))
  defp load(_, _), do: nil

  # As the village tile says it: a find the poet could only call "other" is
  # simply a find.
  defp find_kind("other"), do: dgettext("guide", "Find")
  defp find_kind(kind), do: humanize_category(kind)

  defp subjects(%{topic: a, second_topic: b}) do
    [a, b]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&{&1, PlaceTopics.labels(&1)})
    |> Enum.reject(fn {_path, names} -> is_nil(names) end)
  end

  defp tag(_kind, nil), do: nil
  defp tag(kind, overview), do: Map.put(overview, :kind, kind)

  # The kinds of thing on the item side (Spaces), as the kind filter offers
  # them. Keep in step with KINDS in village.js. A function, so the labels
  # are translated per request.
  defp kinds,
    do: [
      {"", dgettext("guide", "Everything")},
      {"place", dgettext("guide", "Places")},
      {"event", dgettext("guide", "Events")},
      {"artwork", dgettext("guide", "Artworks")},
      {"work", dgettext("guide", "Works")},
      {"idea", dgettext("guide", "Ideas")},
      {"product", dgettext("guide", "Products")}
    ]

  # "3 places", "1 idea": the count and its word, translated whole.
  defp kind_count("place", n), do: dngettext("guide", "%{count} place", "%{count} places", n)
  defp kind_count("event", n), do: dngettext("guide", "%{count} event", "%{count} events", n)

  defp kind_count("artwork", n),
    do: dngettext("guide", "%{count} artwork", "%{count} artworks", n)

  defp kind_count("work", n), do: dngettext("guide", "%{count} work", "%{count} works", n)
  defp kind_count("idea", n), do: dngettext("guide", "%{count} idea", "%{count} ideas", n)

  defp kind_count("product", n),
    do: dngettext("guide", "%{count} product", "%{count} products", n)

  defp kind_count(_other, n), do: dngettext("guide", "%{count} find", "%{count} finds", n)

  # Discover.related/1 words a Spaces link in English; the same words as the
  # item page (ItemHTML.phrase/2), translated here for the reader.
  defp related_phrase("at"), do: dgettext("guide", "at")
  defp related_phrase("here:"), do: dgettext("guide", "here:")
  defp related_phrase("part of"), do: dgettext("guide", "part of")
  defp related_phrase("includes"), do: dgettext("guide", "includes")
  defp related_phrase("made by"), do: dgettext("guide", "made by")
  defp related_phrase("made"), do: dgettext("guide", "made")
  defp related_phrase("commemorates"), do: dgettext("guide", "commemorates")
  defp related_phrase("remembered by"), do: dgettext("guide", "remembered by")
  defp related_phrase("about"), do: dgettext("guide", "about")
  defp related_phrase("the subject of"), do: dgettext("guide", "the subject of")
  defp related_phrase("a later edition of"), do: dgettext("guide", "a later edition of")
  defp related_phrase("returned as"), do: dgettext("guide", "returned as")
  defp related_phrase(phrase), do: phrase

  # The kinds a route can be drawn for: the ones with pins.
  defp routes(%{kinds: kinds}) do
    for kind <- ~w(place event), n = Map.get(kinds, kind, 0), n > 0, do: {kind, n}
  end

  defp routes(_), do: []

  # What else the poet brought back, in a line: "3 works, 2 ideas".
  defp unmapped(%{kinds: kinds}) do
    kinds
    |> Map.drop(~w(place event))
    |> Enum.sort_by(fn {_k, n} -> -n end)
    |> Enum.map_join(", ", fn {kind, n} -> kind_count(kind, n) end)
  end

  defp unmapped(_), do: ""

  @impl true
  def render(%{compact: true} = assigns) do
    ~H"""
    <div class="discover-compact" id="discover-compact">
      <.discover_view
        discover={@discover}
        selected={@selected}
        compact
        me={@me}
        bookmarks={@bookmarks}
      />
      <p class="discover-more">
        <a href={~p"/discover"} class="link" data-track="discover-more">
          {dgettext("guide", "Everything the poets have found, in Discover →")}
        </a>
      </p>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active_tab={:discover}>
      <div class="discover-head">
        <h1 class="text-2xl font-bold">{dgettext("guide", "Discover")}</h1>
        <.totals discover={@discover} />
      </div>

      <%!-- The hook owns aria-pressed from here on: without ignore, every
            re-render put it back to "true" while the layer stayed hidden. --%>
      <div
        class="discover-layers"
        role="group"
        aria-label={dgettext("guide", "Show on the map")}
        id="discover-layers"
        phx-update="ignore"
      >
        <button
          :for={
            {layer, label} <- [
              poets: dgettext("guide", "Poets"),
              entries: dgettext("guide", "Pages"),
              places: dgettext("guide", "Places")
            ]
          }
          type="button"
          class="spread-chip discover-layer"
          data-layer={layer}
          aria-pressed="true"
        >
          <span class={"discover-swatch discover-swatch-#{layer}"} aria-hidden="true"></span>
          {label}
        </button>
      </div>

      <.discover_view discover={@discover} selected={@selected} bookmarks={@bookmarks} />
    </Layouts.app>
    """
  end

  attr :discover, :map, required: true

  # The words between the counts agree with them in Hebrew ("written" is
  # one form in English, two there), hence dngettext with one English form.
  defp totals(assigns) do
    ~H"""
    <p class="text-sm opacity-70" id="discover-totals">
      {@discover.totals.poets} {ngettext("poet", "poets", @discover.totals.poets)} {dgettext(
        "guide",
        "on the road,"
      )} {@discover.totals.entries} {ngettext(
        "page",
        "pages",
        @discover.totals.entries
      )} {dngettext("guide", "written,", "written,", @discover.totals.entries)} {@discover.totals.places} {ngettext(
        "place",
        "places",
        @discover.totals.places
      )} {dngettext("guide", "found.", "found.", @discover.totals.places)}
    </p>
    """
  end

  attr :discover, :map, required: true
  attr :selected, :map, default: nil
  attr :compact, :boolean, default: false
  attr :me, :map, default: nil
  attr :bookmarks, :any, default: nil

  defp discover_view(assigns) do
    ~H"""
    <.totals :if={@compact and @discover.totals.poets > 0} discover={@discover} />
    <%!-- The hook owns aria-pressed, as with the layer toggles. --%>
    <div
      id="discover-views"
      class="discover-views"
      role="group"
      aria-label={dgettext("guide", "How to look")}
      phx-update="ignore"
    >
      <button type="button" data-view="world" aria-pressed="true">
        <.icon name="hero-globe-europe-africa" class="size-4" /> {dgettext("guide", "World")}
      </button>
      <button type="button" data-view="village" aria-pressed="false">
        <.icon name="hero-squares-2x2" class="size-4" /> {dgettext("guide", "Village")}
      </button>
    </div>
    <%!-- The kind filter, for both views; the hook owns aria-selected and the counts. --%>
    <div
      :if={!@compact}
      id="discover-kinds"
      class="discover-kinds"
      role="group"
      aria-label={dgettext("guide", "What to show")}
      phx-update="ignore"
    >
      <button
        :for={{kind, label} <- kinds()}
        type="button"
        class="spread-chip"
        data-kind={kind}
        aria-selected={to_string(kind == "")}
      >
        {label} <small data-kind-count></small>
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
        data-kinds={!@compact && "discover-kinds"}
        data-url={!@compact && "true"}
        class="discover-map rounded-2xl overflow-hidden border border-base-300 z-0"
      >
      </div>

      <aside id="discover-panel" class="discover-panel" aria-live="polite">
        <.overview :if={@selected} selected={@selected} bookmarks={@bookmarks} />
        <p :if={is_nil(@selected) and @me} class="text-sm opacity-60 p-4">
          {dgettext(
            "guide",
            "Here is where %{poet} sets out from. Yours will be the first poet on the road.",
            poet: @me.poet
          )}
        </p>
        <p :if={is_nil(@selected) and is_nil(@me)} class="text-sm opacity-60 p-4">
          {dgettext("guide", "No poets on the road yet. The first ones are still lacing their boots.")}
        </p>
        <div :if={@discover.rotation != []} class="discover-tour-nav">
          <button type="button" class="btn btn-ghost btn-sm" data-discover-prev>
            <.icon name="hero-chevron-left" class="size-4" /> {dgettext(
              "guide",
              "Previous page"
            )}
          </button>
          <button type="button" class="btn btn-ghost btn-sm" data-discover-next>
            {dgettext("guide", "Next page")}
            <.icon name="hero-chevron-right" class="size-4" />
          </button>
        </div>
      </aside>
    </div>
    <p :if={@discover.anonymous != []} class="text-xs opacity-50 mt-2">
      {dgettext("guide", "Grey dots are poets whose journals are private.")}
    </p>
    """
  end

  attr :selected, :map, required: true
  attr :bookmarks, :any, default: nil

  defp overview(%{selected: %{kind: :entry}} = assigns) do
    ~H"""
    <article class="notebook-page discover-card" id={"discover-entry-#{@selected.entry.id}"}>
      <.byline poet={@selected.poet}>
        {entry_when(@selected.entry)}
      </.byline>
      <h2 class="discover-title">{@selected.entry.title}</h2>
      <.section
        :if={@selected.drawing}
        section={%{kind: "illustration"}}
        media={@selected.drawing}
        loading="eager"
      />
      <p :if={@selected.entry.teaser} class="discover-teaser">{@selected.entry.teaser}</p>
      <div class="discover-links">
        <a
          href={~p"/p/#{@selected.poet.slug}/#{Date.to_iso8601(@selected.entry.entry_date)}"}
          class="link"
        >
          {dgettext("guide", "Read this page")}
        </a>
        <button
          type="button"
          class="link"
          phx-click="select"
          phx-value-kind="poet"
          phx-value-id={@selected.poet.slug}
        >
          {dgettext("guide", "More about %{poet}", poet: @selected.poet.name)}
        </button>
      </div>
    </article>
    """
  end

  defp overview(%{selected: %{kind: :place}} = assigns) do
    ~H"""
    <div class="discover-card" id={"discover-place-#{@selected.place.id}"}>
      <.byline poet={@selected.poet}>{dgettext("guide", "recommends")}</.byline>
      <.place_card
        place={@selected.place}
        media={@selected.drawing_from == :place && @selected.drawing}
        poet={@selected.poet}
        saved={saved(@bookmarks, @selected.place)}
      />
      <div :if={@selected.drawing_from == :entry} class="discover-borrowed">
        <.section section={%{kind: "illustration"}} media={@selected.drawing} loading="eager" />
        <p class="text-xs opacity-60">
          {dgettext("guide", "From the page %{poet} wrote there", poet: @selected.poet.name)}
        </p>
      </div>
      <p :if={@selected.also != []} class="discover-also">
        {dgettext("guide", "Also found by %{poets}",
          poets: Enum.map_join(@selected.also, ", ", & &1.name)
        )}
      </p>
      <ul
        :if={@selected.related != []}
        class="discover-related"
        aria-label={dgettext("guide", "Related")}
      >
        <li :for={r <- @selected.related}>
          {related_phrase(r.phrase)}
          <button
            :if={r.place_id}
            type="button"
            class="link"
            phx-click="select"
            phx-value-kind="place"
            phx-value-id={r.place_id}
          >
            {r.name}
          </button>
          <span :if={!r.place_id}>{r.name}</span>
        </li>
      </ul>
      <div
        :if={@selected.topics != []}
        class="discover-subjects"
        aria-label={dgettext("guide", "Subjects")}
      >
        <button
          :for={{path, names} <- @selected.topics}
          type="button"
          class="discover-subject"
          phx-click="village"
          phx-value-topic={path}
          title={dgettext("guide", "See this subject in the village")}
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
          {dgettext("guide", "Open in %{poet}’s guide", poet: @selected.poet.name)}
        </a>
        <a
          href={~p"/p/#{@selected.poet.slug}/#{Date.to_iso8601(@selected.place.entry_date)}"}
          class="link"
        >
          {dgettext("guide", "Read the page it came from")}
        </a>
        <a :if={@selected.item_slug} href={~p"/items/#{@selected.item_slug}"} class="link">
          {dgettext("guide", "Every poet's notes on it")}
        </a>
      </div>
    </div>
    """
  end

  defp overview(%{selected: %{kind: :find}} = assigns) do
    ~H"""
    <div class="discover-card" id={"discover-find-#{@selected.find.id}"}>
      <.byline poet={@selected.poet}>
        {if @selected.destination,
          do:
            dgettext("guide", "brought back from %{destination}", destination: @selected.destination),
          else: dgettext("guide", "brought back")}
      </.byline>
      <div class="flex items-center justify-between gap-2">
        <p class="discover-find-kind">{find_kind(@selected.find.kind)}</p>
        <.save_button
          :if={@bookmarks}
          saved={saved(@bookmarks, @selected.find)}
          kind="find"
          item={@selected.find}
        />
      </div>
      <h2 class="discover-title">{@selected.find.name}</h2>
      <p :if={@selected.find.blurb} class="discover-teaser">{@selected.find.blurb}</p>
      <p :if={@selected.find.poet_rating} class="text-xs opacity-60">
        {dgettext("guide", "%{poet}’s pick: %{rating} of 5",
          poet: @selected.poet.name,
          rating: @selected.find.poet_rating
        )}
      </p>
      <div
        :if={@selected.topics != []}
        class="discover-subjects"
        aria-label={dgettext("guide", "Subjects")}
      >
        <button
          :for={{path, names} <- @selected.topics}
          type="button"
          class="discover-subject"
          phx-click="village"
          phx-value-topic={path}
          title={dgettext("guide", "See this subject in the village")}
        >
          {Enum.join(names, " › ")}
        </button>
      </div>
      <div class="discover-links">
        <a href={@selected.find.url} class="link" target="_blank" rel="noopener">
          {dgettext("guide", "Open it")}
        </a>
        <a
          href={~p"/p/#{@selected.poet.slug}/#{Date.to_iso8601(@selected.entry.entry_date)}"}
          class="link"
        >
          {dgettext("guide", "Read the page it came from")}
        </a>
      </div>
    </div>
    """
  end

  defp overview(%{selected: %{kind: :poet}} = assigns) do
    ~H"""
    <div class="notebook-page discover-card" id={"discover-poet-#{@selected.poet.slug}"}>
      <.byline poet={@selected.poet}>
        {dgettext("guide", "now in %{place}", place: @selected.poet.current_place_name)}
      </.byline>
      <p :if={@selected.latest} class="discover-teaser">
        {dgettext("guide", "Latest page:")}
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
          <span>
            {ngettext("day", "days", @selected.stats.days)} {dgettext("guide", "on the road")}
          </span>
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
      <div
        :if={routes(@selected.stats) != []}
        class="discover-journeys"
        aria-label={dgettext("guide", "Routes")}
      >
        <button
          :for={{kind, n} <- routes(@selected.stats)}
          type="button"
          class="discover-subject"
          phx-click="journey"
          phx-value-poet={@selected.poet.slug}
          phx-value-kind={kind}
          title={dgettext("guide", "Draw the route on the map")}
        >
          {dgettext("guide", "%{things}, in order", things: kind_count(kind, n))}
        </button>
      </div>
      <p :if={unmapped(@selected.stats) != ""} class="text-xs opacity-60 mt-2">
        {dgettext("guide", "Also brought back %{things}.", things: unmapped(@selected.stats))}
      </p>
      <div class="discover-links">
        <a href={~p"/p/#{@selected.poet.slug}"} class="link">
          {dgettext("guide", "Open %{poet}’s journal", poet: @selected.poet.name)}
        </a>
        <a href={~p"/p/#{@selected.poet.slug}/guide"} class="link">
          {dgettext("guide", "%{poet}’s guide", poet: @selected.poet.name)}
        </a>
      </div>
    </div>
    """
  end

  defp entry_when(%{entry_date: date, place_name: place}) do
    day = TravelingPoet.Locale.format_date(date, :month_day)
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
