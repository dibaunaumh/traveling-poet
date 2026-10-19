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

  # Functions, not module attributes: the labels are translated per request.
  def views,
    do: [
      {"map", dgettext("guide", "Map")},
      {"list", dgettext("guide", "List")},
      {"itinerary", dgettext("guide", "Itinerary")}
    ]

  def filters,
    do: [
      {"all", dgettext("guide", "All")},
      {"food", dgettext("guide", "Food")},
      {"sights", dgettext("guide", "Sights")},
      {"events", dgettext("guide", "Events")}
    ]

  # A topic's finds, grouped as Topics.Find.group_for/1 groups them.
  def topic_filters,
    do: [
      {"all", dgettext("guide", "All")},
      {"ideas", dgettext("guide", "Talks and papers")},
      {"works", dgettext("guide", "Art, music, books, films")},
      {"things", dgettext("guide", "Products")},
      {"happenings", dgettext("guide", "Events and venues")}
    ]

  attr :poet, :map, required: true
  attr :stay, :map, default: nil
  attr :view, :string, required: true
  attr :topic, :map, default: nil, doc: "set when the guide shows a topic's excursions"
  attr :saved, :boolean, default: false, doc: "the reader's Saved view"

  def guide_header(assigns) do
    assigns =
      assign(
        assigns,
        :view_options,
        cond do
          assigns.saved ->
            Enum.reject(views(), &(elem(&1, 0) == "itinerary"))

          assigns.topic ->
            [
              {"route", dgettext("guide", "Route")}
              | Enum.reject(views(), &(elem(&1, 0) == "map"))
            ]

          true ->
            views()
        end
      )

    ~H"""
    <div class="flex flex-wrap items-end justify-between gap-4 mb-4">
      <div>
        <h1 class="text-2xl font-semibold">{dgettext("guide", "Trip guide")}</h1>
        <p :if={@saved} class="text-sm opacity-60 mt-1">
          {dgettext("guide", "Places and finds you saved, from any poet")}
        </p>
        <p :if={is_nil(@topic) and not @saved} class="text-sm opacity-60 mt-1">
          <span :if={@stay}>
            {dgettext("guide", "Places, food and events for %{place}", place: @stay.place_name)}
          </span>
          <span :if={is_nil(@stay)}>
            {dgettext("guide", "Places, food and events from %{poet}'s travels", poet: @poet.name)}
          </span>
        </p>
        <p :if={@topic} class="text-sm opacity-60 mt-1">
          {dgettext("guide", "What %{poet} brought back from excursions into %{topic}",
            poet: @poet.name,
            topic: @topic.label
          )}
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

  attr :options, :list,
    default: nil,
    doc: "{key, label} pairs; filters/0 when nil, topic_filters/0 for a topic"

  def filter_chips(assigns) do
    assigns = assign(assigns, :options, assigns.options || filters())

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
  attr :saved_count, :integer, default: 0
  attr :saved, :boolean, default: false, doc: "the Saved view is open"

  @doc """
  One row for every journey the guide can show: the places of the road, then
  each topic with excursions behind it. Rendered only when there is a topic
  to switch to, so a guide with places alone looks exactly as it did. Saved
  (card-70) sits last, once the reader has saved anything.
  """
  def journey_switcher(assigns) do
    ~H"""
    <div
      :if={@journeys != [] or @saved_count > 0 or @saved}
      id="guide-journeys"
      class="flex flex-wrap items-center gap-2 mb-4"
    >
      <button
        id="guide-journey-places"
        phx-click="set_journey"
        phx-value-topic=""
        class={[
          "btn btn-sm",
          if(is_nil(@topic) and not @saved, do: "btn-neutral", else: "btn-ghost")
        ]}
      >
        <.icon name="hero-map-pin" class="size-4" /> {dgettext("guide", "Places")}
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
      <button
        :if={@saved_count > 0 or @saved}
        id="guide-journey-saved"
        phx-click="set_saved"
        class={["btn btn-sm", if(@saved, do: "btn-neutral", else: "btn-ghost")]}
      >
        <.icon name="hero-bookmark" class="size-4" /> {dgettext("guide", "Saved")}
        <span class="opacity-50 text-xs">{@saved_count}</span>
      </button>
    </div>
    """
  end

  attr :excursions, :list, required: true
  attr :excursion, :map, default: nil

  @doc "The destinations of a topic, one pill each, when there is more than one to pick from."
  def destination_switcher(assigns) do
    ~H"""
    <div :if={length(@excursions) > 1} id="guide-destinations" class="flex flex-wrap gap-2 mb-6">
      <button
        id="guide-destination-all"
        phx-click="set_excursion"
        phx-value-excursion=""
        class={["btn btn-xs", if(is_nil(@excursion), do: "btn-secondary", else: "btn-outline")]}
      >
        {dgettext("guide", "All destinations")}
      </button>
      <button
        :for={x <- @excursions}
        id={"guide-destination-#{x.id}"}
        phx-click="set_excursion"
        phx-value-excursion={x.id}
        class={[
          "btn btn-xs",
          if(@excursion && @excursion.id == x.id, do: "btn-secondary", else: "btn-outline")
        ]}
      >
        {destination_label(x)}
      </button>
    </div>
    """
  end

  @doc "A destination's name as the poet gave it, or the excursion's date when it gave none."
  def destination_label(%{destination_name: name}) when is_binary(name) and name != "", do: name

  def destination_label(%{scheduled_for: %Date{} = date}),
    do: dgettext("guide", "Excursion of %{date}", date: format_date(date))

  def destination_label(_), do: dgettext("guide", "Excursion")

  attr :finds, :list, required: true
  attr :excursions, :list, required: true, doc: "to name each find's destination"
  attr :media, :map, required: true
  attr :poet, :map, required: true
  attr :entry_url, :any, default: nil, doc: "fn date -> path of the entry, or nil"
  attr :bookmarks, :any, default: nil, doc: "the reader's saved keys, nil hides Save"

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
        saved={saved(@bookmarks, find)}
      />
    </div>
    """
  end

  attr :find, :map, required: true
  attr :excursion, :map, default: nil
  attr :media, :map, default: nil
  attr :poet, :map, required: true
  attr :entry_url, :any, default: nil
  attr :saved, :any, default: nil, doc: "true/false shows the Save button; nil hides it"
  attr :source, :any, default: nil, doc: "{label, path} to the page it came from"

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

        <div class="flex items-center justify-between gap-2">
          <div class="text-xs opacity-60">
            <span :if={is_nil(@excursion)}>{humanize_category(@find.kind)}</span>
            <span :if={@excursion}>
              {dgettext("guide", "%{kind} at %{destination}",
                kind: humanize_category(@find.kind),
                destination: destination_label(@excursion)
              )}
            </span>
          </div>
          <.save_button :if={is_boolean(@saved)} saved={@saved} kind="find" item={@find} />
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
            {dgettext("guide", "Open ↗")}
          </a>
          <.link
            :if={@entry_url}
            navigate={@entry_url.(@find.entry_date)}
            class="link text-sm opacity-70"
          >
            {dgettext("guide", "Read the entry")}
          </.link>
          <.link :if={@source} navigate={elem(@source, 1)} class="link text-sm opacity-70">
            {elem(@source, 0)}
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
  # in the order they happened, the destination at the top, the finds down the line.
  def excursion_itinerary_view(assigns) do
    ~H"""
    <div id="guide-excursions" class="grid gap-8 md:grid-cols-2 lg:grid-cols-3">
      <div :for={stop <- @find_days} id={"guide-excursion-#{stop.excursion.id}"}>
        <div class="font-semibold">
          {dgettext("guide", "Excursion %{n} into %{topic}", n: stop.n, topic: @topic.label)}
        </div>
        <div class="text-xs opacity-60">
          {format_date(stop.excursion.scheduled_for)}
          <.link
            :if={@entry_url}
            navigate={@entry_url.(stop.excursion.scheduled_for)}
            class="link ms-1"
          >
            {dgettext("guide", "read the entry")}
          </.link>
        </div>
        <div class="text-sm mb-4">
          <a
            :if={stop.excursion.destination_url}
            href={stop.excursion.destination_url}
            target="_blank"
            rel="noopener noreferrer nofollow"
            class="link"
          >
            {destination_label(stop.excursion)}
          </a>
          <span :if={!stop.excursion.destination_url}>{destination_label(stop.excursion)}</span>
        </div>

        <div class="relative ps-6 border-s border-base-300">
          <div :for={find <- stop.finds} class="relative mb-5 flex gap-3">
            <span class="absolute -start-[1.85rem] top-1.5 size-3 rounded-full bg-secondary ring-2 ring-base-100"></span>
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
          <p :if={stop.finds == []} class="text-xs opacity-50 mb-5">
            {dgettext("guide", "Nothing under this filter.")}
          </p>
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
      <div class="font-semibold">{dgettext("guide", "Still gathering recommendations")}</div>
      <p class="text-sm mt-1">
        {dgettext(
          "guide",
          "%{poet} hasn't mapped out this trip's guide yet — it fills in as the journal grows.",
          poet: @poet.name
        )}
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
  attr :bookmarks, :any, default: nil, doc: "the reader's saved keys, nil hides Save"
  attr :poets, :map, default: nil, doc: "poet_id => poet, when places come from several poets"
  attr :sources, :map, default: %{}, doc: "place id => {label, path}"
  attr :hint, :string, default: nil

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
          poet={poet_for(@poets, @selected, @poet)}
          saved={saved(@bookmarks, @selected)}
          source={@sources[@selected.id]}
        />
        <p :if={is_nil(@selected)} class="text-sm opacity-60 p-4">
          {@hint ||
            dgettext("guide", "Pick a pin to see what %{poet} said about it.", poet: @poet.name)}
        </p>
      </div>
    </div>

    <p :if={@unmapped > 0} class="text-xs opacity-50 mt-3">{unmapped_note(@unmapped)}</p>
    """
  end

  attr :places, :list, required: true
  attr :media, :map, required: true
  attr :poet, :map, required: true
  attr :bookmarks, :any, default: nil, doc: "the reader's saved keys, nil hides Save"
  attr :poets, :map, default: nil, doc: "poet_id => poet, when places come from several poets"
  attr :sources, :map, default: %{}, doc: "place id => {label, path}"

  def list_view(assigns) do
    ~H"""
    <div id="guide-list" class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
      <.place_card
        :for={place <- @places}
        place={place}
        media={@media[place.media_id]}
        poet={poet_for(@poets, place, @poet)}
        saved={saved(@bookmarks, place)}
        source={@sources[place.id]}
      />
    </div>
    """
  end

  defp poet_for(nil, _item, poet), do: poet
  defp poet_for(poets, item, poet), do: Map.get(poets, item.poet_id) || poet

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
          <span :if={is_nil(@stay) or is_nil(@stay.place_name)}>
            {dgettext("guide", "Day %{n}", n: day.day)}
          </span>
          <span :if={@stay && @stay.place_name}>
            {dgettext("guide", "Day %{n} in %{place}", n: day.day, place: @stay.place_name)}
          </span>
        </div>
        <div class="text-xs opacity-60 mb-4">{format_date(day.date)}</div>

        <div class="relative ps-6 border-s border-base-300">
          <div :for={place <- day.places} class="relative mb-5 flex gap-3">
            <span class="absolute -start-[1.85rem] top-1.5 size-3 rounded-full bg-secondary ring-2 ring-base-100"></span>
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
  attr :saved, :any, default: nil, doc: "true/false shows the Save button; nil hides it"
  attr :source, :any, default: nil, doc: "{label, path} to the page it came from"

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

        <div class="flex items-center justify-between gap-2">
          <div class="text-xs opacity-60">{humanize_category(@place.category)}</div>
          <.save_button :if={is_boolean(@saved)} saved={@saved} kind="place" item={@place} />
        </div>
        <.event_dates place={@place} />
        <.hours_line place={@place} />
        <.poet_pick :if={@place.poet_rating} place={@place} poet={@poet} />

        <p :if={@place.blurb} class="text-sm opacity-80 leading-relaxed">{@place.blurb}</p>
        <div :if={@place.address} class="text-xs opacity-50">{@place.address}</div>

        <div class="flex flex-wrap gap-x-4 gap-y-1">
          <a
            :if={@place.source_url}
            href={@place.source_url}
            target="_blank"
            rel="noopener noreferrer nofollow"
            class="link link-primary text-sm"
          >
            {dgettext("guide", "View details ↗")}
          </a>
          <a
            :if={TravelingPoet.MapsLinks.google_url(@place)}
            id={"maps-#{@place.id}"}
            href={TravelingPoet.MapsLinks.google_url(@place)}
            target="_blank"
            rel="noopener noreferrer"
            class="link text-sm opacity-80"
          >
            {dgettext("guide", "Open in Google Maps ↗")}
          </a>
        </div>
        <.link :if={@source} navigate={elem(@source, 1)} class="link text-xs opacity-70">
          {elem(@source, 0)}
        </.link>
      </div>
    </div>
    """
  end

  attr :place, :map, required: true

  @doc "Opening hours as the poet read them, and whether to book ahead."
  def hours_line(assigns) do
    ~H"""
    <div
      :if={Map.get(@place, :hours) || Map.get(@place, :book_ahead)}
      class="flex flex-wrap items-center gap-2 text-xs"
    >
      <span :if={Map.get(@place, :hours)} class="opacity-70">
        {dgettext("guide", "Open %{hours}", hours: Map.get(@place, :hours))}
      </span>
      <span :if={Map.get(@place, :book_ahead)} class="badge badge-sm badge-outline">
        {dgettext("guide", "Book ahead")}
      </span>
    </div>
    """
  end

  attr :id, :string, default: "saved-to-maps"
  attr :kml_url, :string, required: true

  @doc """
  Saved places into Google Maps. Google offers no way for an app to fill a
  Maps list, so this is the My Maps route: import the file once, and the
  map shows in the Google Maps app under Saved and can be shared from there.
  """
  def maps_export(assigns) do
    ~H"""
    <details id={@id} class="mt-3 text-sm">
      <summary class="cursor-pointer link">
        {dgettext("guide", "Put these places in Google Maps")}
      </summary>
      <ol class="mt-2 ms-5 list-decimal space-y-1 opacity-80">
        <li>
          <a href={@kml_url} class="link">{dgettext("guide", "Download the places file")}</a>.
        </li>
        <li>
          <.rich text={
            dgettext("guide", "Open %{my_maps}, create a map, and choose Import with that file.",
              my_maps: marker(:my_maps)
            )
          }>
            <:part name="my_maps">
              <a
                href="https://www.google.com/mymaps"
                target="_blank"
                rel="noopener noreferrer"
                class="link"
              >Google My Maps</a>
            </:part>
          </.rich>
        </li>
        <li>
          {dgettext(
            "guide",
            "The map appears in the Google Maps app under Saved, then Maps. Use Share there to send it to friends."
          )}
        </li>
      </ol>
    </details>
    """
  end

  attr :token, :string, default: nil

  @doc "The owner's switch for sharing their Saved list with friends (card-93)."
  def share_saved(assigns) do
    ~H"""
    <div id="share-saved" class="mt-3 flex flex-wrap items-center gap-2 text-sm">
      <button
        :if={is_nil(@token)}
        type="button"
        id="share-saved-start"
        phx-click="share_saved"
        class="btn btn-sm"
      >
        {dgettext("guide", "Share this list with friends")}
      </button>
      <div :if={@token} class="flex flex-wrap items-center gap-2">
        <span class="opacity-70">
          {dgettext("guide", "Anyone with this link sees these places:")}
        </span>
        <a id="share-saved-link" href={~p"/shared/#{@token}"} target="_blank" class="link break-all">
          {url(~p"/shared/#{@token}")}
        </a>
        <button
          type="button"
          id="share-saved-stop"
          phx-click="stop_sharing"
          class="btn btn-ghost btn-xs"
        >
          {dgettext("guide", "Stop sharing")}
        </button>
      </div>
    </div>
    """
  end

  attr :plan, :list, required: true, doc: "`Guide.DayPlan.plan/2`"
  attr :days, :integer, required: true

  @doc """
  Plan my days (card-91): the saved places split into days by part of town,
  each day in the order you would walk it, with its route in Google Maps.
  """
  def day_plan(assigns) do
    ~H"""
    <section id="day-plan" class="mt-4 rounded-box border border-base-300 bg-base-200 p-4">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 class="font-semibold">{dgettext("guide", "Plan my days")}</h2>
          <p class="text-xs opacity-70">
            {dgettext(
              "guide",
              "Your saved places, grouped by part of town and in walking order: coffee first, dinner last."
            )}
          </p>
        </div>
        <form id="day-plan-form" phx-change="plan_days" class="flex items-center gap-2 text-sm">
          <label for="day-plan-days">{dgettext("guide", "Days")}</label>
          <select id="day-plan-days" name="days" class="select select-sm w-20">
            <option :for={n <- 1..7} value={n} selected={n == @days}>{n}</option>
          </select>
        </form>
      </div>

      <p :if={length(@plan) < @days} id="day-plan-fewer" class="mt-3 text-sm opacity-70">
        {dngettext(
          "guide",
          "Your saved places fit in %{count} day, so the rest are free.",
          "Your saved places fit in %{count} days, so the rest are free.",
          length(@plan)
        )}
      </p>
      <ol class="mt-4 grid gap-4 md:grid-cols-2 xl:grid-cols-3">
        <li :for={day <- @plan} id={"plan-day-#{day.day}"} class="rounded-box bg-base-100 p-3">
          <div class="flex items-baseline justify-between gap-2">
            <h3 class="font-semibold text-sm">{dgettext("guide", "Day %{n}", n: day.day)}</h3>
            <a
              :if={day.route_url}
              id={"plan-route-#{day.day}"}
              href={day.route_url}
              target="_blank"
              rel="noopener noreferrer"
              class="link text-xs"
            >
              {dgettext("guide", "Walk it in Google Maps ↗")}
            </a>
          </div>
          <ol class="mt-2 space-y-2">
            <li :for={{place, i} <- Enum.with_index(day.places, 1)} class="flex gap-2 text-sm">
              <span class="opacity-50 tabular-nums">{i}.</span>
              <div>
                <div>
                  <span class="font-medium">{place.name}</span>
                  <span class="text-xs opacity-60">{humanize_category(place.category)}</span>
                </div>
                <.hours_line place={place} />
              </div>
            </li>
          </ol>
        </li>
      </ol>
    </section>
    """
  end

  attr :saved, :boolean, required: true
  attr :kind, :string, required: true
  attr :item, :map, required: true

  @doc "Save or unsave a place or find; rendered only for a signed-in reader."
  def save_button(assigns) do
    ~H"""
    <button
      type="button"
      id={"save-#{@kind}-#{@item.id}"}
      phx-click="toggle_bookmark"
      phx-value-kind={@kind}
      phx-value-id={@item.id}
      class={["btn btn-ghost btn-xs gap-1 px-1", @saved && "text-primary"]}
      aria-pressed={to_string(@saved)}
      title={
        if @saved,
          do: dgettext("guide", "Saved. Tap to remove"),
          else: dgettext("guide", "Save to your guide")
      }
    >
      <.icon name={if @saved, do: "hero-bookmark-solid", else: "hero-bookmark"} class="size-4" />
      <span class="text-xs">
        {if @saved,
          do: dpgettext("guide", "save button", "Saved"),
          else: dgettext("guide", "Save")}
      </span>
    </button>
    """
  end

  @doc "Whether an item is in the reader's saved keys; nil when there is no reader."
  def saved(nil, _item), do: nil
  def saved(keys, item), do: TravelingPoet.Bookmarks.saved?(keys, item)

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
      <span :if={@ended} class="badge badge-ghost badge-xs">{dgettext("guide", "ended")}</span>
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
      title={dgettext("guide", "%{poet}'s own rating — not a review score", poet: @poet.name)}
    >
      <span class="text-warning">{String.duplicate("★", @place.poet_rating)}</span>
      <span class="opacity-60">{dgettext("guide", "%{poet}'s pick", poet: @poet.name)}</span>
    </div>
    """
  end

  # Taste-day find kinds read better as what they are. Every category and
  # kind is a closed list (Guide.Place, Topics.Find), so each has its
  # translation; anything else is shown as it came.
  def humanize_category("screen"), do: dgettext("guide", "Film or series")
  def humanize_category("outing"), do: dgettext("guide", "Outdoors")
  def humanize_category("restaurant"), do: dgettext("guide", "Restaurant")
  def humanize_category("cafe"), do: dgettext("guide", "Cafe")
  def humanize_category("viewpoint"), do: dgettext("guide", "Viewpoint")
  def humanize_category("attraction"), do: dgettext("guide", "Attraction")
  def humanize_category("event"), do: dgettext("guide", "Event")
  def humanize_category("landmark"), do: dgettext("guide", "Landmark")
  def humanize_category("shop"), do: dgettext("guide", "Shop")
  def humanize_category("artwork"), do: dgettext("guide", "Artwork")
  def humanize_category("dish"), do: dgettext("guide", "Dish")
  def humanize_category("person"), do: dgettext("guide", "Person")
  def humanize_category("talk"), do: dgettext("guide", "Talk")
  def humanize_category("paper"), do: dgettext("guide", "Paper")
  def humanize_category("product"), do: dgettext("guide", "Product")
  def humanize_category("session"), do: dgettext("guide", "Session")
  def humanize_category("venue"), do: dgettext("guide", "Venue")
  def humanize_category("music"), do: dgettext("guide", "Music")
  def humanize_category("book"), do: dgettext("guide", "Book")
  def humanize_category("other"), do: dgettext("guide", "Other")
  def humanize_category(category), do: String.capitalize(category)

  def format_date(%Date{} = date), do: TravelingPoet.Locale.format_date(date, :short)
  def format_date(_), do: ""

  defp unmapped_note(n),
    do:
      dngettext(
        "guide",
        "One place couldn't be put on the map — it's still in the list.",
        "%{count} places couldn't be put on the map — they're still in the list.",
        n
      )
end
