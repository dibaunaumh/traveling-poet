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
  """

  use TravelingPoetWeb, :live_view

  import TravelingPoetWeb.NotebookComponents, only: [section: 1]
  import TravelingPoetWeb.GuideComponents, only: [place_card: 1]

  alias TravelingPoet.Discover

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "journal:published")
    end

    discover = Discover.build()

    {:ok,
     socket
     |> assign(:page_title, "Discover")
     |> assign(:discover, discover)
     |> assign(:selected, first_selection(discover))}
  end

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

  @impl true
  def handle_info({:journal_published, _poet_id, _entry_id}, socket) do
    discover = Discover.build()

    {:noreply,
     socket
     |> assign(:discover, discover)
     |> push_event("discover:update", discover)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # The page opens on the tour's first page, so the dead render (and a
  # reader without JavaScript) already shows something worth reading.
  defp first_selection(%{rotation: [id | _]}), do: load("entry", id)
  defp first_selection(_), do: nil

  defp load("entry", id), do: tag(:entry, Discover.entry(id))
  defp load("place", id), do: tag(:place, Discover.place(id))
  defp load("poet", slug) when is_binary(slug), do: tag(:poet, Discover.poet(slug))
  defp load(_, _), do: nil

  defp tag(_kind, nil), do: nil
  defp tag(kind, overview), do: Map.put(overview, :kind, kind)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active_tab={:discover}>
      <div class="discover-head">
        <h1 class="text-2xl font-bold">Discover</h1>
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

      <div class="discover-grid">
        <div
          id="discover-map"
          phx-hook="DiscoverMap"
          phx-update="ignore"
          data-discover={Jason.encode!(@discover)}
          data-panel="discover-panel"
          data-layers="discover-layers"
          class="discover-map rounded-2xl overflow-hidden border border-base-300 z-0"
        >
        </div>

        <aside id="discover-panel" class="discover-panel" aria-live="polite">
          <.overview :if={@selected} selected={@selected} />
          <p :if={is_nil(@selected)} class="text-sm opacity-60 p-4">
            Nothing on the road yet. The first poets are setting out.
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
    </Layouts.app>
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
      <.place_card place={@selected.place} media={@selected.drawing} poet={@selected.poet} />
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
