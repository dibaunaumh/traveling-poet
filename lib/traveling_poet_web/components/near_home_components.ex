defmodule TravelingPoetWeb.NearHomeComponents do
  @moduledoc """
  "Near you" (card-71) on screen: the journal's card for the week's picks,
  and the cards, map pins and Google Maps places of `NearHomeLive`. Every
  pick is owner-only: it shows where the reader lives.
  """

  use TravelingPoetWeb, :html

  alias TravelingPoet.NearHome.Pick

  attr :picks, :list, required: true, doc: "`NearHome.this_week/1`"
  attr :poet, :map, required: true
  attr :home, :string, required: true

  @doc "The journal's card: what the poet found near home this week, a tap from the list."
  def near_home_card(assigns) do
    ~H"""
    <div :if={@picks != []} id="near-home-card" class="alert alert-soft text-sm mt-4 flex-wrap">
      <.icon name="hero-home-modern" class="size-5 shrink-0" />
      <span class="flex-1 min-w-48">
        <span class="font-medium">
          {dngettext(
            "guide",
            "Near you this week: %{poet} found one thing around %{home}.",
            "Near you this week: %{poet} found %{count} things around %{home}.",
            length(@picks),
            poet: @poet.name,
            home: @home
          )}
        </span>
        <span class="opacity-70">{Enum.map_join(Enum.take(@picks, 3), ", ", & &1.name)}</span>
      </span>
      <.link navigate={~p"/guide/near"} class="btn btn-primary btn-sm" id="near-home-card-open">
        {dgettext("guide", "See when and where")}
      </.link>
    </div>
    """
  end

  attr :pick, Pick, required: true
  attr :n, :integer, required: true

  @doc "One pick: what, when, where, how far, why it fits, and the page it was read on."
  def pick_card(assigns) do
    ~H"""
    <article id={"near-pick-#{@pick.id}"} class="card bg-base-100 border border-base-300">
      <div class="card-body p-4 gap-2">
        <div class="flex items-start gap-3">
          <span class="badge badge-sm badge-neutral shrink-0 mt-0.5">{@n}</span>
          <div class="min-w-0 flex-1">
            <h3 class="font-semibold leading-snug" dir="auto">{@pick.name}</h3>
            <p class="text-xs opacity-60">
              {kind_label(@pick.kind)}
              <span :if={@pick.distance_km}>
                · {dgettext("guide", "%{km} km from home", km: km(@pick.distance_km))}
              </span>
            </p>
          </div>
        </div>
        <p :if={when_line(@pick)} class="text-sm font-medium" id={"near-pick-#{@pick.id}-when"}>
          {when_line(@pick)}
        </p>
        <p :if={@pick.when_text && (@pick.starts_on || @pick.ends_on)} class="text-xs opacity-70">
          {@pick.when_text}
        </p>
        <p :if={where_line(@pick)} class="text-xs opacity-70" dir="auto">{where_line(@pick)}</p>
        <p :if={@pick.blurb} class="text-sm" dir="auto">{@pick.blurb}</p>
        <div class="flex flex-wrap gap-x-4 gap-y-1 text-xs mt-1">
          <a href={@pick.url} target="_blank" rel="noopener noreferrer nofollow" class="link">
            {dgettext("guide", "Details ↗")}
          </a>
          <a
            :if={directions_url(@pick)}
            href={directions_url(@pick)}
            target="_blank"
            rel="noopener noreferrer"
            class="link"
          >
            {dgettext("guide", "Directions ↗")}
          </a>
        </div>
      </div>
    </article>
    """
  end

  @doc "The kind of a pick, in the reader's language."
  def kind_label("event"), do: dgettext("guide", "Event")
  def kind_label("exhibition"), do: dgettext("guide", "Exhibition")
  def kind_label("market"), do: dgettext("guide", "Market")
  def kind_label("performance"), do: dgettext("guide", "Performance")
  def kind_label("place"), do: dgettext("guide", "Place")
  def kind_label("outing"), do: dgettext("guide", "Outing")
  def kind_label(_), do: dgettext("guide", "Something to do")

  @doc """
  When to go, from the pick's dates: a day, a range, "until" for something
  already running, "from" for something with no end. Nil when it has only
  the poet's `when_text`, which the card shows instead.
  """
  def when_line(%Pick{starts_on: nil, ends_on: nil, when_text: text}), do: text

  def when_line(%Pick{starts_on: from, ends_on: to}) do
    today = Date.utc_today()

    cond do
      from && to && Date.compare(from, today) == :lt ->
        dgettext("guide", "Until %{date}", date: day(to))

      from && to ->
        TravelingPoet.Trips.date_range(from, to)

      from ->
        dgettext("guide", "From %{date}", date: day(from))

      true ->
        dgettext("guide", "Until %{date}", date: day(to))
    end
  end

  @doc "The venue and its address, without saying the venue twice when the address starts with it."
  def where_line(%Pick{place_name: venue, address: address}) do
    cond do
      venue && address && String.contains?(address, venue) -> address
      venue || address -> Enum.join(Enum.reject([venue, address], &is_nil/1), ", ")
      true -> nil
    end
  end

  @doc "Where a pick is, as the place Google Maps should save: the venue when there is one."
  def google_place(%Pick{} = pick),
    do: %{name: pick.place_name || pick.name, address: pick.address, lat: pick.lat, lng: pick.lng}

  @doc "Map pins in the shape `PoetMap` reads from data-places."
  def map_payload(picks) do
    picks
    |> Enum.with_index(1)
    |> Enum.filter(fn {p, _n} -> is_number(p.lat) and is_number(p.lng) end)
    |> Enum.map(fn {p, n} ->
      %{
        id: p.id,
        n: n,
        lat: p.lat,
        lng: p.lng,
        name: p.name,
        category: kind_label(p.kind),
        group: if(p.kind in ~w(place outing other), do: "sights", else: "events"),
        blurb: p.blurb,
        url: p.url
      }
    end)
  end

  defp directions_url(%Pick{lat: lat, lng: lng}) when is_number(lat) and is_number(lng),
    do: "https://www.google.com/maps/dir/?api=1&destination=#{lat},#{lng}"

  defp directions_url(_), do: nil

  defp day(date), do: TravelingPoet.Locale.format_date(date, :day_month)

  defp km(distance) when distance < 10, do: :erlang.float_to_binary(distance / 1, decimals: 1)
  defp km(distance), do: round(distance)
end
