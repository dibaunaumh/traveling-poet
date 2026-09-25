defmodule TravelingPoetWeb.NotebookComponents do
  @moduledoc """
  The pieces of a journal page that every surface renders the same way — the
  owner's journal, a public journal, and the home page's open spread — so an
  entry looks like the same notebook wherever it is read.
  """

  use TravelingPoetWeb, :html

  alias TravelingPoet.Guide.Place
  alias TravelingPoet.Journal.{Blank, Media}
  alias TravelingPoet.Topics
  alias TravelingPoetWeb.GuideComponents

  attr :entry, :map, required: true
  attr :day, :integer, default: nil, doc: "journey day, see Journal.journey_day/2"
  attr :tag, :string, default: "h2"
  attr :show_date, :boolean, default: true

  @doc """
  The entry's heading, the same on every surface: the journey day in the
  margin hand, the poet's title (falling back to the place, then "Journal"),
  and the date. The day comes from the app, never from the stored title. An
  excursion entry names its topic where a place entry has nothing to add.
  """
  def entry_heading(assigns) do
    assigns = assign(assigns, :excursion_label, excursion_label(assigns.entry))

    ~H"""
    <.dynamic_tag tag_name={@tag} class="notebook-title">
      <span :if={@day} class="notebook-day">Day {@day}</span>
      {entry_title(@entry)}
      <span :if={@show_date} class="notebook-date ml-2">
        {Calendar.strftime(@entry.entry_date, "%B %-d, %Y")}
      </span>
      <span :if={@excursion_label} class="notebook-excursion">
        Excursion: {@excursion_label}
      </span>
    </.dynamic_tag>
    """
  end

  def entry_title(entry) do
    Blank.clean(entry.title) || excursion_destination(entry) || excursion_label(entry) ||
      entry.place_name || "Journal"
  end

  @doc "The topic of an excursion entry, nil for a day at a place."
  def excursion_label(entry) do
    case excursion_of(entry) do
      %{topic: %{label: label}} when is_binary(label) -> label
      _ -> nil
    end
  end

  defp excursion_destination(entry) do
    case excursion_of(entry) do
      %{destination_name: name} when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  # Only what the caller loaded: a heading never queries. The journal views
  # preload `excursion: :topic`; a bare map in a test carries the key or not.
  defp excursion_of(entry) do
    case Map.get(entry, :excursion) do
      %Ecto.Association.NotLoaded{} -> nil
      other -> other
    end
  end

  attr :entry, :map, required: true
  attr :spread, :map, required: true, doc: "one spread from Journal.Spreads.pack/3"
  attr :day, :integer, default: nil
  attr :media, :map, default: %{}, doc: "media by id, for illustration sections"
  attr :clamp, :boolean, default: false, doc: "cut prose to a few lines (home page)"
  attr :place_links, :list, default: [], doc: "see place_links/2"
  attr :spot_media, :map, default: %{}, doc: "the entry's spot drawings by id"
  attr :heading_tag, :string, default: "h2"
  attr :show_date, :boolean, default: true
  attr :rest, :global, doc: "id, hooks and data attributes for the article"

  slot :meta, doc: "above the heading on the left page"
  slot :controls, doc: "beside the heading: marker menu, earlier/later links"
  slot :left_footer
  slot :right_footer, doc: "under the drawing and poem: prompt, reactions"

  @doc """
  An entry open across two facing pages. The article is the unit the Markers
  hook attaches to, so every markable block inside keeps the `.marker-target`
  contract (one `.prose`, section kind and position, media id) whichever page
  it lands on.
  """
  def entry_spread(assigns) do
    ~H"""
    <article class="spread" {@rest}>
      <div class="notebook-page spread-page spread-left">
        {render_slot(@meta)}
        <div class="flex items-start justify-between gap-2 mb-2">
          <.entry_heading entry={@entry} day={@day} tag={@heading_tag} show_date={@show_date} />
          <div :if={@controls != []} class="flex items-center gap-1 shrink-0">
            {render_slot(@controls)}
          </div>
        </div>
        <.spread_item
          :for={item <- @spread.left}
          item={item}
          entry={@entry}
          media={@media}
          clamp={@clamp}
          links={@place_links}
          spot_media={@spot_media}
        />
        <p :if={@spread.left == []} class="prose text-sm opacity-60">
          A quiet page. The drawing says it all today.
        </p>
        {render_slot(@left_footer)}
      </div>
      <div class={[
        "notebook-page spread-page spread-right",
        @spread.right == [] and @right_footer == [] and "spread-page-empty"
      ]}>
        <.spread_item
          :for={item <- @spread.right}
          item={item}
          entry={@entry}
          media={@media}
          clamp={@clamp}
          links={@place_links}
          spot_media={@spot_media}
        />
        {render_slot(@right_footer)}
      </div>
    </article>
    """
  end

  attr :item, :any, required: true
  attr :entry, :map, required: true
  attr :media, :map, required: true
  attr :clamp, :boolean, default: false
  attr :links, :list, default: []
  attr :spot_media, :map, default: %{}

  # The id and data attributes come from the section's stored position, not
  # its place on the page: the Markers hook matches marks by (kind, position)
  # and the tests pin `section-<entry>-0`.
  defp spread_item(%{item: {:section, section}} = assigns) do
    assigns = assign(assigns, :section, section)

    ~H"""
    <div
      id={"section-#{@entry.id}-#{@section.position}"}
      class="mb-6 marker-target"
      data-section-kind={@section.kind}
      data-section-position={@section.position}
      data-media-id={@section.media_id}
    >
      <.section
        section={@section}
        media={@media[@section.media_id]}
        clamp={@clamp and @section.kind != "illustration"}
        links={@links}
        spot_media={@spot_media}
      />
    </div>
    """
  end

  defp spread_item(%{item: {:media, media}} = assigns) do
    assigns = assign(assigns, :drawing, media)

    ~H"""
    <div
      id={"media-#{@entry.id}-#{@drawing.id}"}
      class="mb-6 marker-target"
      data-section-kind="illustration"
      data-media-id={@drawing.id}
    >
      <.section section={%{kind: "illustration"}} media={@drawing} />
    </div>
    """
  end

  attr :entry, :map, required: true
  attr :spread, :map, required: true, doc: "the Places spread from Journal.Spreads.pack/4"
  attr :day, :integer, default: nil
  attr :poet, :map, required: true
  attr :place_media, :map, default: %{}, doc: "media by id, for place drawings"
  attr :guide_url, :string, required: true, doc: "the guide, opened on this entry's stay"
  attr :stay_count, :integer, default: 0, doc: "places in the whole stay"
  attr :rest, :global

  slot :map, required: true, doc: "the map element; the caller owns its hook and payload"
  slot :controls

  @doc """
  The Places spread: the day's map taped onto the left page, the stops the
  poet would send you to on the right, each under its passport stamp. The
  full stay lives in the guide, one link away.
  """
  def places_spread(assigns) do
    stops = for {:place, place} <- assigns.spread.right, do: place
    assigns = assign(assigns, stops: stops, mapped: Enum.count(stops, &Place.mapped?/1))

    ~H"""
    <article class="spread" {@rest}>
      <div class="notebook-page spread-page spread-left">
        <div class="flex items-start justify-between gap-2 mb-2">
          <.entry_heading entry={@entry} day={@day} />
          <div :if={@controls != []} class="flex items-center gap-1 shrink-0">
            {render_slot(@controls)}
          </div>
        </div>
        <figure class="taped-map">
          {render_slot(@map)}
        </figure>
        <p class="notebook-caption">
          <span :if={@stops == []}>Nowhere in particular today.</span>
          <span :if={@stops != [] and @mapped == length(@stops)}>
            {stop_count(@stops)} on the map.
          </span>
          <span :if={@stops != [] and @mapped < length(@stops)}>
            {stop_count(@stops)}, {@mapped} on the map.
          </span>
        </p>
      </div>
      <div class="notebook-page spread-page spread-right">
        <h3 class="notebook-section-title mb-3">Where {@poet.name} would send you</h3>
        <ol :if={@stops != []} class="stops">
          <li :for={{place, n} <- Enum.with_index(@stops, 1)} id={"stop-#{place.id}"} class="stop">
            <.place_stamp place={place} n={n} />
            <div class="stop-body">
              <div class="stop-name">{place.name}</div>
              <GuideComponents.event_dates place={place} />
              <GuideComponents.poet_pick :if={place.poet_rating} place={place} poet={@poet} />
              <p :if={place.blurb} class="stop-blurb">{place.blurb}</p>
              <div :if={place.address} class="stop-address">{place.address}</div>
              <img
                :if={@place_media[place.media_id]}
                src={~p"/media/#{place.media_id}"}
                alt={@place_media[place.media_id].alt_text || place.name}
                class="stop-drawing"
                loading="lazy"
              />
            </div>
          </li>
        </ol>
        <p :if={@stops == []} class="prose text-sm opacity-60">
          No places logged for this day. The guide has the rest of the trip.
        </p>
        <div class="spread-actions">
          <a href={@guide_url} class="link">
            <span :if={@stay_count > 0}>
              All {@stay_count} {ngettext("place", "places", @stay_count)} in {@entry.place_name ||
                "the guide"} &rarr;
            </span>
            <span :if={@stay_count == 0}>Open the guide &rarr;</span>
          </a>
        </div>
      </div>
    </article>
    """
  end

  defp stop_count(stops), do: "#{length(stops)} #{ngettext("stop", "stops", length(stops))}"

  attr :entry, :map, required: true
  attr :spread, :map, required: true, doc: "the Finds spread from Journal.Spreads.pack/4"
  attr :day, :integer, default: nil
  attr :poet, :map, required: true
  attr :find_media, :map, default: %{}, doc: "media by id, for find drawings"

  attr :guide_url, :string,
    default: nil,
    doc: "the topic in the owner's guide; nil on public pages"

  attr :rest, :global

  slot :controls

  @doc """
  The Finds spread of an excursion entry: the ticket for the day off the
  road on the left (where the poet went and for which topic), and what it
  brought back on the right, each under its stamp. No map: a find is a link,
  not an address, and nothing here reaches the trip guide.
  """
  def finds_spread(assigns) do
    finds = for {:find, find} <- assigns.spread.right, do: find
    [{:excursion, excursion}] = assigns.spread.left
    assigns = assign(assigns, finds: finds, excursion: excursion)

    ~H"""
    <article class="spread" {@rest}>
      <div class="notebook-page spread-page spread-left">
        <div class="flex items-start justify-between gap-2 mb-2">
          <.entry_heading entry={@entry} day={@day} />
          <div :if={@controls != []} class="flex items-center gap-1 shrink-0">
            {render_slot(@controls)}
          </div>
        </div>
        <figure class="taped-ticket">
          <div class="ticket-kicker">A day off the road</div>
          <div class="ticket-topic">{Topics.label_for_entry(@entry) || "an excursion"}</div>
          <div :if={@excursion.destination_name} class="ticket-destination">
            <a
              :if={@excursion.destination_url}
              href={@excursion.destination_url}
              target="_blank"
              rel="noopener noreferrer nofollow"
            >
              {@excursion.destination_name}
            </a>
            <span :if={!@excursion.destination_url}>{@excursion.destination_name}</span>
          </div>
          <div :if={@excursion.source == "chat"} class="ticket-note">
            You asked for this one in chat.
          </div>
          <div :if={@poet.current_place_name} class="ticket-note">
            Written from {@poet.current_place_name}.
          </div>
        </figure>
        <p class="notebook-caption">
          <span :if={@finds == []}>Nothing to take home today.</span>
          <span :if={@finds != []}>{find_count(@finds)} worth your time.</span>
        </p>
      </div>
      <div class="notebook-page spread-page spread-right">
        <h3 class="notebook-section-title mb-3">What {@poet.name} brought back</h3>
        <ol :if={@finds != []} class="stops">
          <li :for={{find, n} <- Enum.with_index(@finds, 1)} id={"find-#{find.id}"} class="stop">
            <.find_stamp find={find} n={n} />
            <div class="stop-body">
              <div class="stop-name">
                <a href={find.url} target="_blank" rel="noopener noreferrer nofollow">
                  {find.name}
                </a>
              </div>
              <GuideComponents.poet_pick :if={find.poet_rating} place={find} poet={@poet} />
              <p :if={find.blurb} class="stop-blurb">{find.blurb}</p>
              <img
                :if={@find_media[find.media_id]}
                src={~p"/media/#{find.media_id}"}
                alt={@find_media[find.media_id].alt_text || find.name}
                class="stop-drawing"
                loading="lazy"
              />
            </div>
          </li>
        </ol>
        <p :if={@finds == []} class="prose text-sm opacity-60">
          No finds logged for this excursion.
        </p>
        <div :if={@guide_url} class="spread-actions">
          <a href={@guide_url} class="link">
            Everything from excursions into {Topics.label_for_entry(@entry) || "this topic"} &rarr;
          </a>
        </div>
      </div>
    </article>
    """
  end

  defp find_count(finds), do: "#{length(finds)} #{ngettext("find", "finds", length(finds))}"

  attr :find, :map, required: true
  attr :n, :integer, required: true

  @doc """
  The stamp for a find: the same inked ring as a place stamp, coloured by
  what kind of thing it is. Links to the find's own page.
  """
  def find_stamp(assigns) do
    assigns = assign(assigns, color: find_color(assigns.find.kind))

    ~H"""
    <a
      href={@find.url}
      target="_blank"
      rel="noopener noreferrer nofollow"
      class="place-stamp"
      style={"--stamp-c: #{@color}"}
      title={"Open #{@find.name}"}
    >
      <span class="stamp-n">{@n}</span>
      <span class="stamp-name">{@find.name}</span>
      <span class="stamp-cat">{GuideComponents.humanize_category(@find.kind)}</span>
      <span class="stamp-date">{GuideComponents.format_date(@find.entry_date)}</span>
    </a>
    """
  end

  # Ideas in indigo, works in madder red, things in ochre, happenings in the
  # events purple.
  # Public so the book's gazetteer inks its list the same way.
  @doc false
  def find_color(kind) when kind in ~w(paper talk session), do: "#3b4a8c"
  def find_color("product"), do: "#b7791f"
  def find_color(kind) when kind in ~w(music book screen), do: "#a33b3b"
  def find_color(kind) when kind in ~w(event venue outing), do: "#8e44ad"
  def find_color(_), do: "#0f766e"

  attr :place, :map, required: true
  attr :n, :integer, required: true

  @doc """
  A rubber stamp for a place: name, category and date inside an inked ring,
  coloured by the guide's filter group so it matches the pin on the map. It
  links to the place's own page (already link-checked when the poet logged
  it). Drawn in CSS, never a fetched logo: the app shows nothing it did not
  make itself.
  """
  def place_stamp(assigns) do
    assigns =
      assign(assigns,
        color: stamp_color(Place.group_for(assigns.place.category)),
        href: assigns.place.source_url
      )

    ~H"""
    <a
      href={@href || "#stop-#{@place.id}"}
      target={@href && "_blank"}
      rel={@href && "noopener noreferrer nofollow"}
      class="place-stamp"
      style={"--stamp-c: #{@color}"}
      title={if @href, do: "Open #{@place.name}'s page", else: @place.name}
    >
      <span class="stamp-n">{@n}</span>
      <span class="stamp-name">{@place.name}</span>
      <span class="stamp-cat">{GuideComponents.humanize_category(@place.category)}</span>
      <span class="stamp-date">{GuideComponents.format_date(@place.entry_date)}</span>
    </a>
    """
  end

  # The same three inks as the map pins (poet_map_hook.js GROUP_COLORS).
  @doc false
  def stamp_color("food"), do: "#c0392b"
  def stamp_color("events"), do: "#8e44ad"
  def stamp_color(_), do: "#0f766e"

  attr :spreads, :list, required: true
  attr :active, :string, required: true
  attr :patch, :any, required: true, doc: "fn key -> path, the tab's patch target"
  attr :chat, :boolean, default: false, doc: "add a Chat tab that opens the sidebar"
  attr :chat_open, :boolean, default: false, doc: "whether the desktop sidebar is showing"

  @doc """
  The notebook's index tabs: one per spread, plus Chat on the owner's journal.
  Chat is not a page (the sidebar has uploads, live replies and the sprite
  hold), so its tab only opens the sidebar, or the overlay on a phone.
  """
  def spread_tabs(assigns) do
    ~H"""
    <nav class="spread-tabs" role="tablist" aria-label="Pages of this entry">
      <.link
        :for={s <- @spreads}
        patch={@patch.(s.key)}
        role="tab"
        aria-selected={to_string(s.key == @active)}
        class="spread-tab"
      >
        {s.label}
      </.link>
      <span :if={@chat} class="hidden xl:contents">
        <button
          type="button"
          role="tab"
          aria-selected={to_string(@chat_open)}
          title={if @chat_open, do: "Hide the chat", else: "Show the chat"}
          class="spread-tab"
          phx-click="toggle_chat"
        >
          Chat
        </button>
      </span>
      <span :if={@chat} class="xl:hidden contents">
        <button
          type="button"
          role="tab"
          aria-selected="false"
          class="spread-tab"
          phx-click="toggle_mobile_chat"
        >
          Chat
        </button>
      </span>
    </nav>
    """
  end

  @doc """
  Earlier/later links around the entry being read, as ISO strings: `Date`
  has no `Phoenix.Param`, and a bare struct in `~p` crashes the render (only
  once a poet has two entries, which is why day one never caught it).
  """
  def entry_nav(entries, current) do
    dates = entries |> Enum.map(& &1.entry_date) |> Enum.sort(Date)
    idx = Enum.find_index(dates, &(&1 == current.entry_date))

    prev =
      if idx && idx > 0,
        do: [{"← earlier", Date.to_iso8601(Enum.at(dates, idx - 1))}],
        else: []

    next =
      if idx && idx < length(dates) - 1,
        do: [{"later →", Date.to_iso8601(Enum.at(dates, idx + 1))}],
        else: []

    prev ++ next
  end

  attr :section, :any, required: true
  attr :media, :any, default: nil
  attr :clamp, :boolean, default: false, doc: "cap the prose at a few lines (home page spread)"
  attr :links, :list, default: [], doc: "place links to weave into the prose, see place_links/2"

  attr :spot_media, :map,
    default: %{},
    doc: "the entry's spot drawings by id: the only images a body may embed"

  @doc "One journal section: a taped-on illustration, or a titled block of the poet's prose."
  def section(%{section: %{kind: "illustration"}} = assigns) do
    ~H"""
    <figure :if={@media} class="taped-photo my-4">
      <img
        src={~p"/media/#{@media.id}"}
        alt={@media.alt_text || "illustration"}
        class="rounded-xl max-w-full shadow"
        loading="lazy"
      />
      <figcaption class="text-xs opacity-60 mt-1 flex flex-wrap gap-x-3">
        <span :if={@media.alt_text}>{@media.alt_text}</span>
        <a
          :for={src <- Media.source_items(@media)}
          href={src["url"]}
          target="_blank"
          rel="noopener noreferrer nofollow"
          class="link"
        >
          {src["label"] || "see the real place"} ↗
        </a>
      </figcaption>
    </figure>
    """
  end

  def section(assigns) do
    assigns = assign(assigns, :spots, embedded_spots(assigns.section.body, assigns.spot_media))

    ~H"""
    <div class={@section.kind == "poem" && "notebook-poem"}>
      <h3 :if={Blank.present?(@section.title)} class="notebook-section-title mb-1">
        <span class="section-icon">{section_icon(@section.kind)}</span> {@section.title}
      </h3>
      <div class={["prose prose-sm max-w-none", @clamp && "spread-clamp"]}>
        {raw_markdown(@section.body, @spot_media, @links)}
      </div>
      <%!-- every drawing cites what it was drawn from, the small ones too:
            the drawing links to its reference, and this line names them.
            Outside .prose so the markers' text offsets are untouched. --%>
      <div :if={@spots != []} class="spot-sources">
        Drawn from
        <a
          :for={src <- Enum.flat_map(@spots, &Media.source_items/1)}
          href={src["url"]}
          target="_blank"
          rel="noopener noreferrer nofollow"
          class="link"
        >
          {src["label"] || "the real place"} ↗
        </a>
      </div>
      <a
        :if={@section.metadata["source_url"]}
        href={@section.metadata["source_url"]}
        target="_blank"
        rel="noopener noreferrer nofollow"
        class="link text-sm"
      >
        {@section.metadata["source_label"] || @section.metadata["source_url"]} ↗
      </a>
    </div>
    """
  end

  @doc """
  The poet's markdown as sanitized HTML.

  Section bodies come from the sprite, which is user-driven territory, so
  they are cleaned the same way chat is. Images are the one place the rule
  goes further than the sanitizer: a drawing may only be embedded from this
  app's own `/media/:id` route, and only when the caller vouches for the id
  (`allowed_media_ids`, the poet's own media for this entry). Anything else,
  which would be a photo found online, collapses to its alt text. That keeps
  the "never embed photos you find online" rule in `priv/data/AGENTS.md`
  enforced here rather than only in the prompt.
  """
  def raw_markdown(text, allowed_media_ids \\ [], place_links \\ [])

  def raw_markdown(nil, _allowed, _links), do: ""

  def raw_markdown(text, allowed_media, place_links) do
    # a map of id => media lets the drawing link to what it was drawn from;
    # a bare list of ids only lets it through
    allowed =
      Map.new(allowed_media, fn
        {id, media} -> {to_string(id), media}
        id -> {to_string(id), nil}
      end)

    with {:ok, doc} <- MDEx.parse_document(text),
         doc = MDEx.traverse_and_update(doc, &own_images_only(&1, allowed)),
         doc = %{doc | nodes: link_places(doc.nodes, place_links)},
         {:ok, html} <- MDEx.to_html(doc, sanitize: MDEx.Document.default_sanitize_options()) do
      Phoenix.HTML.raw(html)
    else
      _ -> text
    end
  end

  # The spot drawings a body actually embeds, in order, so their sources can
  # be listed under it.
  defp embedded_spots(nil, _spot_media), do: []
  defp embedded_spots(_body, spot_media) when map_size(spot_media) == 0, do: []

  defp embedded_spots(body, spot_media) do
    ~r{\]\(/media/(\d+)\)}
    |> Regex.scan(body)
    |> Enum.map(fn [_, id] -> Map.get(spot_media, String.to_integer(id)) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
  end

  @doc """
  The links `raw_markdown/3` weaves into the prose: the first mention of each
  of the entry's places becomes a link to its stop on the Places spread, so
  a name in the text is a way into the guide. Built by the journals, since
  the path differs between the owner's and a public one.
  """
  # Below this a name is a word ("Bar", "Sur") that would link half the prose.
  @min_name 4

  def place_links(places, base_path) do
    places
    |> Enum.filter(&(is_binary(&1.name) and String.length(String.trim(&1.name)) >= @min_name))
    |> Enum.map(&%{name: String.trim(&1.name), href: "#{base_path}?spread=places#stop-#{&1.id}"})
  end

  # Walks the AST once, threading the places still unlinked, so each name
  # links exactly once: at its first mention anywhere in the body. Text
  # already inside a link (the poet's own) is left alone, as are images and
  # code. Only text nodes are split, so the visible text is unchanged and the
  # feedback markers' offsets still hold.
  defp link_places(nodes, []), do: nodes

  defp link_places(nodes, links) do
    links = Enum.sort_by(links, &(-String.length(&1.name)))
    {nodes, _left} = walk(nodes, links, Enum.map(links, & &1.name))
    nodes
  end

  # `all` is every name, linked or not: a shorter name never matches inside
  # a mention of a longer one ("Cafe" inside "Cafe Museum"), even once the
  # longer one has had its link, or the reader would be sent to the wrong stop.
  defp walk(nodes, links, all) do
    {rev, links} =
      Enum.reduce(nodes, {[], links}, fn node, {acc, links} ->
        {replaced, links} = walk_node(node, links, all)
        {Enum.reverse(replaced, acc), links}
      end)

    {Enum.reverse(rev), links}
  end

  defp walk_node(node, [], _all), do: {[node], []}
  defp walk_node(%MDEx.Text{literal: text}, links, all), do: link_text(text, links, all)
  defp walk_node(%MDEx.Link{} = node, links, _all), do: {[node], links}
  defp walk_node(%MDEx.Image{} = node, links, _all), do: {[node], links}
  defp walk_node(%MDEx.Code{} = node, links, _all), do: {[node], links}

  defp walk_node(%{nodes: children} = node, links, all) do
    {children, links} = walk(children, links, all)
    {[%{node | nodes: children}], links}
  end

  defp walk_node(node, links, _all), do: {[node], links}

  # The earliest mention of any still-unlinked place wins; a tie goes to the
  # longer name. Both sides of the cut are walked again with what is left.
  defp link_text(text, links, all) do
    links
    |> Enum.map(&{&1, first_mention(text, &1.name, longer_than(&1.name, all))})
    |> Enum.reject(fn {_, at} -> is_nil(at) end)
    |> Enum.min_by(fn {_, {start, len}} -> {start, -len} end, fn -> nil end)
    |> case do
      nil ->
        {text_nodes(text), links}

      {link, {start, len}} ->
        before = binary_part(text, 0, start)
        mention = binary_part(text, start, len)
        rest = binary_part(text, start + len, byte_size(text) - start - len)
        remaining = List.delete(links, link)

        {before_nodes, remaining} = link_text(before, remaining, all)
        {rest_nodes, remaining} = link_text(rest, remaining, all)

        anchor = %MDEx.Link{
          url: link.href,
          # "" not nil: MDEx cannot encode a link with a nil title
          title: "",
          nodes: [%MDEx.Text{literal: mention}]
        }

        {before_nodes ++ [anchor] ++ rest_nodes, remaining}
    end
  end

  defp text_nodes(""), do: []
  defp text_nodes(text), do: [%MDEx.Text{literal: text}]

  defp longer_than(name, all), do: Enum.filter(all, &(String.length(&1) > String.length(name)))

  # The first whole-word, case-insensitive mention that does not sit inside
  # a mention of a longer name. Byte offsets, so binary_part cuts cleanly.
  defp first_mention(text, name, shadows) do
    covered = Enum.flat_map(shadows, &mentions(text, &1))

    Enum.find(mentions(text, name), fn {start, len} ->
      not Enum.any?(covered, fn {s, l} -> start >= s and start + len <= s + l end)
    end)
  end

  defp mentions(text, name) do
    ~r/(?<![\p{L}\p{N}])#{Regex.escape(name)}(?![\p{L}\p{N}])/iu
    |> Regex.scan(text, return: :index)
    |> Enum.map(&hd/1)
  end

  defp own_images_only(%MDEx.Image{url: "/media/" <> id} = image, allowed) do
    case Map.fetch(allowed, id) do
      {:ok, nil} -> image
      {:ok, media} -> cite(image, media)
      :error -> alt_text(image)
    end
  end

  defp own_images_only(%MDEx.Image{} = image, _allowed), do: alt_text(image)
  defp own_images_only(node, _allowed), do: node

  # The drawing itself is the citation: tapping it opens the reference it
  # was drawn from, so the credit sits on the drawing and not a screen away
  # at the end of a long section. No text is added, so marker offsets hold.
  defp cite(image, media) do
    case Media.source_items(media) do
      [%{"url" => url} | _] = items when is_binary(url) ->
        labels = items |> Enum.map(&(&1["label"] || &1["url"])) |> Enum.join(", ")
        %MDEx.Link{url: url, title: "Drawn from #{labels}", nodes: [image]}

      _ ->
        image
    end
  end

  defp alt_text(%MDEx.Image{nodes: nodes}) do
    %MDEx.Text{literal: Enum.map_join(nodes, "", &node_text/1)}
  end

  defp node_text(%MDEx.Text{literal: literal}), do: literal
  defp node_text(%{nodes: nodes}), do: Enum.map_join(nodes, "", &node_text/1)
  defp node_text(_), do: ""

  def section_icon("poem"), do: "✒️"
  def section_icon("description"), do: "🗺️"
  def section_icon("art_culture"), do: "🎭"
  def section_icon("products"), do: "🧺"
  def section_icon("kindness"), do: "💛"
  def section_icon(_), do: ""
end
