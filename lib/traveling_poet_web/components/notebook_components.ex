defmodule TravelingPoetWeb.NotebookComponents do
  @moduledoc """
  The pieces of a journal page that every surface renders the same way — the
  owner's journal, a public journal, and the home page's open spread — so an
  entry looks like the same notebook wherever it is read.
  """

  use TravelingPoetWeb, :html

  alias TravelingPoet.Guide.Place
  alias TravelingPoet.Journal.Media
  alias TravelingPoetWeb.GuideComponents

  attr :entry, :map, required: true
  attr :day, :integer, default: nil, doc: "journey day, see Journal.journey_day/2"
  attr :tag, :string, default: "h2"
  attr :show_date, :boolean, default: true

  @doc """
  The entry's heading, the same on every surface: the journey day in the
  margin hand, the poet's title (falling back to the place, then "Journal"),
  and the date. The day comes from the app, never from the stored title.
  """
  def entry_heading(assigns) do
    ~H"""
    <.dynamic_tag tag_name={@tag} class="notebook-title">
      <span :if={@day} class="notebook-day">Day {@day}</span>
      {entry_title(@entry)}
      <span :if={@show_date} class="notebook-date ml-2">
        {Calendar.strftime(@entry.entry_date, "%B %-d, %Y")}
      </span>
    </.dynamic_tag>
    """
  end

  def entry_title(entry), do: entry.title || entry.place_name || "Journal"

  attr :entry, :map, required: true
  attr :spread, :map, required: true, doc: "one spread from Journal.Spreads.pack/3"
  attr :day, :integer, default: nil
  attr :media, :map, default: %{}, doc: "media by id, for illustration sections"
  attr :clamp, :boolean, default: false, doc: "cut prose to a few lines (home page)"
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
  defp stamp_color("food"), do: "#c0392b"
  defp stamp_color("events"), do: "#8e44ad"
  defp stamp_color(_), do: "#0f766e"

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
      <span :if={@chat} class="hidden lg:contents">
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
      <span :if={@chat} class="lg:hidden contents">
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
    ~H"""
    <div class={@section.kind == "poem" && "notebook-poem"}>
      <h3 :if={@section.title} class="notebook-section-title mb-1">
        {section_icon(@section.kind)} {@section.title}
      </h3>
      <div class={["prose prose-sm max-w-none", @clamp && "spread-clamp"]}>
        {raw_markdown(@section.body)}
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
  def raw_markdown(text, allowed_media_ids \\ [])

  def raw_markdown(nil, _allowed), do: ""

  def raw_markdown(text, allowed_media_ids) do
    allowed = MapSet.new(allowed_media_ids, &to_string/1)

    with {:ok, doc} <- MDEx.parse_document(text),
         doc = MDEx.traverse_and_update(doc, &own_images_only(&1, allowed)),
         {:ok, html} <- MDEx.to_html(doc, sanitize: MDEx.Document.default_sanitize_options()) do
      Phoenix.HTML.raw(html)
    else
      _ -> text
    end
  end

  defp own_images_only(%MDEx.Image{url: "/media/" <> id} = image, allowed) do
    if MapSet.member?(allowed, id), do: image, else: alt_text(image)
  end

  defp own_images_only(%MDEx.Image{} = image, _allowed), do: alt_text(image)
  defp own_images_only(node, _allowed), do: node

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
