defmodule TravelingPoetWeb.GuideComponents do
  @moduledoc """
  The trip guide's rendering, shared by the owner's `/guide` and the public
  `/p/:slug/guide`.

  Every control emits the same events (`set_view`, `set_filter`, `set_stay`,
  `select_place`), so both LiveViews implement the same small handler set and
  the markup never forks. The two differ only in where they push_patch to.
  """

  use TravelingPoetWeb, :html

  alias TravelingPoet.Guide.Place

  @views [{"map", "Map"}, {"list", "List"}, {"itinerary", "Itinerary"}]
  @filters [{"all", "All"}, {"food", "Food"}, {"sights", "Sights"}, {"events", "Events"}]
  # A topic's finds, grouped as Topics.Find.group_for/1 groups them.
  @topic_filters [
    {"all", "All"},
    {"ideas", "Talks and papers"},
    {"things", "Products"},
    {"happenings", "Events and venues"}
  ]

  def views, do: @views
  def filters, do: @filters
  def topic_filters, do: @topic_filters

  attr :poet, :map, required: true
  attr :stay, :map, default: nil
  attr :view, :string, required: true
  attr :topic, :map, default: nil, doc: "set when the guide shows a topic's excursions"

  def guide_header(assigns) do
    assigns =
      assign(
        assigns,
        :view_options,
        if(assigns.topic,
          do: [{"route", "Route"} | Enum.reject(@views, &(elem(&1, 0) == "map"))],
          else: @views
        )
      )

    ~H"""
    <div class="flex flex-wrap items-end justify-between gap-4 mb-4">
      <div>
        <h1 class="text-2xl font-semibold">Trip guide</h1>
        <p :if={is_nil(@topic)} class="text-sm opacity-60 mt-1">
          Places, food and events <span :if={@stay}>for {@stay.place_name}</span>
          <span :if={is_nil(@stay)}>from {@poet.name}'s travels</span>
        </p>
        <p :if={@topic} class="text-sm opacity-60 mt-1">
          What {@poet.name} brought back from excursions into {@topic.label}
        </p>
      </div>

      <div id="guide-views" class="flex gap-1 bg-base-200 rounded-full p-1">
        <button
          :for={{key, label} <- @view_options}
          id={"guide-view-#{key}"}
          phx-click="set_view"
          phx-value-view={key}
          class={[
            "btn btn-sm rounded-full border-none",
            if(@view == key, do: "btn-primary", else: "btn-ghost")
          ]}
        >
          {label}
        </button>
      </div>
    </div>
    """
  end

  attr :filter, :string, required: true
  attr :counts, :map, required: true
  attr :options, :list, default: @filters, doc: "{key, label} pairs; topic_filters/0 for a topic"

  def filter_chips(assigns) do
    ~H"""
    <div id="guide-filters" class="flex flex-wrap gap-2 mb-4">
      <button
        :for={{key, label} <- @options}
        id={"guide-filter-#{key}"}
        phx-click="set_filter"
        phx-value-filter={key}
        class={["btn btn-sm", if(@filter == key, do: "btn-primary", else: "btn-ghost")]}
      >
        {label}
        <span class="opacity-50 text-xs">{@counts[key]}</span>
      </button>
    </div>
    """
  end

  attr :stays, :list, required: true
  attr :stay, :map, default: nil

  def stay_switcher(assigns) do
    ~H"""
    <div :if={length(@stays) > 1} id="guide-stays" class="flex flex-wrap gap-2 mb-6">
      <button
        :for={stay <- @stays}
        id={"guide-stay-#{stay.id}"}
        phx-click="set_stay"
        phx-value-stay={stay.id}
        class={[
          "btn btn-xs",
          if(@stay && @stay.id == stay.id, do: "btn-secondary", else: "btn-outline")
        ]}
      >
        {stay.place_name}
      </button>
    </div>
    """
  end

  attr :journeys, :list, required: true, doc: "[{topic, excursion_count}] from GuideState"
  attr :topic, :map, default: nil

  @doc """
  One row for every journey the guide can show: the places of the road, then
  each topic with excursions behind it. Rendered only when there is a topic
  to switch to, so a guide with places alone looks exactly as it did.
  """
  def journey_switcher(assigns) do
    ~H"""
    <div :if={@journeys != []} id="guide-journeys" class="flex flex-wrap items-center gap-2 mb-4">
      <button
        id="guide-journey-places"
        phx-click="set_journey"
        phx-value-topic=""
        class={["btn btn-sm", if(is_nil(@topic), do: "btn-neutral", else: "btn-ghost")]}
      >
        <.icon name="hero-map-pin" class="size-4" /> Places
      </button>
      <button
        :for={{topic, count} <- @journeys}
        id={"guide-journey-topic-#{topic.id}"}
        phx-click="set_journey"
        phx-value-topic={topic.id}
        class={[
          "btn btn-sm",
          if(@topic && @topic.id == topic.id, do: "btn-neutral", else: "btn-ghost")
        ]}
      >
        <.icon name="hero-book-open" class="size-4" /> {topic.label}
        <span class="opacity-50 text-xs">{count}</span>
      </button>
    </div>
    """
  end

  attr :excursions, :list, required: true
  attr :excursion, :map, default: nil

  @doc "The venues of a topic, one pill each, when there is more than one to pick from."
  def venue_switcher(assigns) do
    ~H"""
    <div :if={length(@excursions) > 1} id="guide-venues" class="flex flex-wrap gap-2 mb-6">
      <button
        id="guide-venue-all"
        phx-click="set_excursion"
        phx-value-excursion=""
        class={["btn btn-xs", if(is_nil(@excursion), do: "btn-secondary", else: "btn-outline")]}
      >
        All venues
      </button>
      <button
        :for={x <- @excursions}
        id={"guide-venue-#{x.id}"}
        phx-click="set_excursion"
        phx-value-excursion={x.id}
        class={[
          "btn btn-xs",
          if(@excursion && @excursion.id == x.id, do: "btn-secondary", else: "btn-outline")
        ]}
      >
        {venue_label(x)}
      </button>
    </div>
    """
  end

  @doc "A venue's name as the poet gave it, or the excursion's date when it gave none."
  def venue_label(%{venue_name: name}) when is_binary(name) and name != "", do: name
  def venue_label(%{scheduled_for: %Date{} = date}), do: "Excursion of #{format_date(date)}"
  def venue_label(_), do: "Excursion"

  attr :finds, :list, required: true
  attr :excursions, :list, required: true, doc: "to name each find's venue"
  attr :media, :map, required: true
  attr :poet, :map, required: true
  attr :entry_url, :any, default: nil, doc: "fn date -> path of the entry, or nil"

  def find_list_view(assigns) do
    assigns = assign(assigns, :by_entry, Map.new(assigns.excursions, &{&1.journal_entry_id, &1}))

    ~H"""
    <div id="guide-finds" class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
      <.find_card
        :for={find <- @finds}
        find={find}
        excursion={@by_entry[find.journal_entry_id]}
        media={@media[find.media_id]}
        poet={@poet}
        entry_url={@entry_url}
      />
    </div>
    """
  end

  attr :find, :map, required: true
  attr :excursion, :map, default: nil
  attr :media, :map, default: nil
  attr :poet, :map, required: true
  attr :entry_url, :any, default: nil

  def find_card(assigns) do
    ~H"""
    <div id={"find-#{@find.id}"} class="card bg-base-200 border border-base-300 overflow-hidden">
      <img
        :if={@media}
        src={~p"/media/#{@find.media_id}"}
        alt={@media.alt_text || @find.name}
        class="h-36 w-full object-cover"
      />
      <div class="card-body p-4 gap-2">
        <div class="flex items-start justify-between gap-2">
          <h3 class="font-semibold leading-snug">{@find.name}</h3>
          <span class="badge badge-warning badge-sm whitespace-nowrap">
            {format_date(@find.entry_date)}
          </span>
        </div>

        <div class="text-xs opacity-60">
          {humanize_category(@find.kind)}<span :if={@excursion}> at {venue_label(@excursion)}</span>
        </div>
        <.poet_pick :if={@find.poet_rating} place={@find} poet={@poet} />

        <p :if={@find.blurb} class="text-sm opacity-80 leading-relaxed">{@find.blurb}</p>

        <div class="flex flex-wrap gap-3">
          <a
            href={@find.url}
            target="_blank"
            rel="noopener noreferrer nofollow"
            class="link link-primary text-sm"
          >
            Open ↗
          </a>
          <.link
            :if={@entry_url}
            navigate={@entry_url.(@find.entry_date)}
            class="link text-sm opacity-70"
          >
            Read the entry
          </.link>
        </div>
      </div>
    </div>
    """
  end

  attr :find_days, :list, required: true, doc: "from GuideState: [%{n, excursion, finds}]"
  attr :topic, :map, required: true
  attr :media, :map, required: true
  attr :poet, :map, required: true
  attr :entry_url, :any, default: nil

  # The same shape as a stay's itinerary: one column per excursion, numbered
  # in the order they happened, the venue at the top, the finds down the line.
  def excursion_itinerary_view(assigns) do
    ~H"""
    <div id="guide-excursions" class="grid gap-8 md:grid-cols-2 lg:grid-cols-3">
      <div :for={stop <- @find_days} id={"guide-excursion-#{stop.excursion.id}"}>
        <div class="font-semibold">Excursion {stop.n} into {@topic.label}</div>
        <div class="text-xs opacity-60">
          {format_date(stop.excursion.scheduled_for)}
          <.link
            :if={@entry_url}
            navigate={@entry_url.(stop.excursion.scheduled_for)}
            class="link ml-1"
          >
            read the entry
          </.link>
        </div>
        <div class="text-sm mb-4">
          <a
            :if={stop.excursion.venue_url}
            href={stop.excursion.venue_url}
            target="_blank"
            rel="noopener noreferrer nofollow"
            class="link"
          >
            {venue_label(stop.excursion)}
          </a>
          <span :if={!stop.excursion.venue_url}>{venue_label(stop.excursion)}</span>
        </div>

        <div class="relative pl-6 border-l border-base-300">
          <div :for={find <- stop.finds} class="relative mb-5 flex gap-3">
            <span class="absolute -left-[1.85rem] top-1.5 size-3 rounded-full bg-secondary ring-2 ring-base-100"></span>
            <img
              :if={@media[find.media_id]}
              src={~p"/media/#{find.media_id}"}
              alt={find.name}
              class="size-14 rounded-lg object-cover flex-shrink-0"
            />
            <div>
              <a
                href={find.url}
                target="_blank"
                rel="noopener noreferrer nofollow"
                class="font-semibold text-sm link link-hover"
              >
                {find.name}
              </a>
              <div class="text-xs opacity-60">{humanize_category(find.kind)}</div>
              <.poet_pick :if={find.poet_rating} place={find} poet={@poet} />
            </div>
          </div>
          <p :if={stop.finds == []} class="text-xs opacity-50 mb-5">Nothing under this filter.</p>
        </div>
      </div>
    </div>
    """
  end

  attr :poet, :map, required: true

  def empty_state(assigns) do
    ~H"""
    <div id="guide-empty" class="text-center py-16 opacity-70">
      <.icon name="hero-map" class="size-8 mb-3 opacity-50" />
      <div class="font-semibold">Still gathering recommendations</div>
      <p class="text-sm mt-1">
        {@poet.name} hasn't mapped out this trip's guide yet — it fills in as the journal grows.
      </p>
    </div>
    """
  end

  # Rendered only while selected so Leaflet initialises in a visible container;
  # a map mounted hidden comes up grey until invalidateSize().
  attr :map_places, :list, required: true
  attr :selected, :map, default: nil
  attr :media, :map, required: true
  attr :poet, :map, required: true
  attr :unmapped, :integer, default: 0

  def map_view(assigns) do
    ~H"""
    <div class="grid gap-5 lg:grid-cols-2 items-start">
      <div
        id="guide-map"
        phx-hook="PoetMap"
        phx-update="ignore"
        data-places={Jason.encode!(@map_places)}
        class="h-[420px] rounded-2xl overflow-hidden border border-base-300 z-0"
      >
      </div>

      <div>
        <.place_card
          :if={@selected}
          place={@selected}
          media={@media[@selected.media_id]}
          poet={@poet}
        />
        <p :if={is_nil(@selected)} class="text-sm opacity-60 p-4">
          Pick a pin to see what {@poet.name} said about it.
        </p>
      </div>
    </div>

    <p :if={@unmapped > 0} class="text-xs opacity-50 mt-3">{unmapped_note(@unmapped)}</p>
    """
  end

  attr :places, :list, required: true
  attr :media, :map, required: true
  attr :poet, :map, required: true

  def list_view(assigns) do
    ~H"""
    <div id="guide-list" class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
      <.place_card :for={place <- @places} place={place} media={@media[place.media_id]} poet={@poet} />
    </div>
    """
  end

  attr :days, :list, required: true
  attr :media, :map, required: true
  attr :poet, :map, required: true
  attr :stay, :map, default: nil, doc: "the path point these days belong to"

  # "Day 2 in Vienna", not a bare "Day 2": the journal numbers the whole
  # journey, so an unqualified count here would read as a contradiction.
  def itinerary_view(assigns) do
    ~H"""
    <div id="guide-itinerary" class="grid gap-8 md:grid-cols-2 lg:grid-cols-3">
      <div :for={day <- @days} id={"guide-day-#{day.day}"}>
        <div class="font-semibold">
          Day {day.day}<span :if={@stay && @stay.place_name}> in {@stay.place_name}</span>
        </div>
        <div class="text-xs opacity-60 mb-4">{format_date(day.date)}</div>

        <div class="relative pl-6 border-l border-base-300">
          <div :for={place <- day.places} class="relative mb-5 flex gap-3">
            <span class="absolute -left-[1.85rem] top-1.5 size-3 rounded-full bg-secondary ring-2 ring-base-100"></span>
            <img
              :if={@media[place.media_id]}
              src={~p"/media/#{place.media_id}"}
              alt={place.name}
              class="size-14 rounded-lg object-cover flex-shrink-0"
            />
            <div>
              <div class="font-semibold text-sm">{place.name}</div>
              <div class="text-xs opacity-60">{humanize_category(place.category)}</div>
              <.event_dates place={place} />
              <.poet_pick :if={place.poet_rating} place={place} poet={@poet} />
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :place, :map, required: true
  attr :media, :map, default: nil
  attr :poet, :map, required: true

  def place_card(assigns) do
    ~H"""
    <div id={"place-#{@place.id}"} class="card bg-base-200 border border-base-300 overflow-hidden">
      <img
        :if={@media}
        src={~p"/media/#{@place.media_id}"}
        alt={@media.alt_text || @place.name}
        class="h-36 w-full object-cover"
      />
      <div class="card-body p-4 gap-2">
        <div class="flex items-start justify-between gap-2">
          <h3 class="font-semibold leading-snug">{@place.name}</h3>
          <span class="badge badge-warning badge-sm whitespace-nowrap">
            {format_date(@place.entry_date)}
          </span>
        </div>

        <div class="text-xs opacity-60">{humanize_category(@place.category)}</div>
        <.event_dates place={@place} />
        <.poet_pick :if={@place.poet_rating} place={@place} poet={@poet} />

        <p :if={@place.blurb} class="text-sm opacity-80 leading-relaxed">{@place.blurb}</p>
        <div :if={@place.address} class="text-xs opacity-50">{@place.address}</div>

        <a
          :if={@place.source_url}
          href={@place.source_url}
          target="_blank"
          rel="noopener noreferrer nofollow"
          class="link link-primary text-sm"
        >
          View details ↗
        </a>
      </div>
    </div>
    """
  end

  # An event with no dates cannot be planned around, and one whose dates have
  # passed must say so rather than sit in the guide looking current -- the
  # whole failure mode here is a reader travelling for a closed exhibition.
  attr :place, :map, required: true

  def event_dates(assigns) do
    assigns =
      assign(assigns,
        range: Place.date_range(assigns.place),
        ended: Place.ended?(assigns.place, Date.utc_today())
      )

    ~H"""
    <div :if={@range} class="text-xs flex items-center gap-1" data-testid="event-dates">
      <.icon name="hero-calendar-days" class="size-3 opacity-50" />
      <span class={[@ended && "opacity-50 line-through"]}>{@range}</span>
      <span :if={@ended} class="badge badge-ghost badge-xs">ended</span>
    </div>
    """
  end

  # The rating is the poet's own opinion and it has to say so. A bare star
  # beside a restaurant reads as a sourced review score, which is exactly what
  # this number is not.
  attr :place, :map, required: true
  attr :poet, :map, required: true

  def poet_pick(assigns) do
    ~H"""
    <div
      class="text-xs flex items-center gap-1"
      data-testid="poet-pick"
      title={"#{@poet.name}'s own rating — not a review score"}
    >
      <span class="text-warning">{String.duplicate("★", @place.poet_rating)}</span>
      <span class="opacity-60">{@poet.name}'s pick</span>
    </div>
    """
  end

  def humanize_category(category), do: String.capitalize(category)

  def format_date(%Date{} = date), do: Calendar.strftime(date, "%b %-d")
  def format_date(_), do: ""

  defp unmapped_note(1), do: "One place couldn't be put on the map — it's still in the list."

  defp unmapped_note(n),
    do: "#{n} places couldn't be put on the map — they're still in the list."
end
