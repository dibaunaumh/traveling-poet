defmodule TravelingPoet.Poets.Showcase do
  @moduledoc """
  The fleet as a reader waiting for their own first entry sees it: every
  public poet's journey, the drawings along it and a few numbers, plus the
  private poets as anonymous dots. Feeds the journey tour on the journal
  while entry #0 is being written.

  Also the home of `blurred_point/1`, the one rule for how a private poet
  appears on any map: coordinates rounded to ~10km and nothing else. See
  `Poets.list_poets_on_the_road/0`.
  """

  import Ecto.Query

  alias TravelingPoet.{Guide, Poets, Repo}
  alias TravelingPoet.Journal.{Entry, Media}
  alias TravelingPoet.Poets.PathPoint

  @stops_per_poet 6

  @doc """
  Builds the showcase. `my_poet` (the reader's own, usually not yet on the
  road) is reported under `:me` and never among `:poets`, so the tour can
  mark where it starts without a card of its own.

      %{
        me: %{lat, lng, name, poet} | nil,
        poets: [%{slug, name, avatar, mine, current, path, stops, stats, latest_url}],
        anonymous: [%{lat, lng}],
        totals: %{poets, entries, places, countries, drawings}
      }

  Each stop is a published entry with coordinates, newest last, carrying the
  entry's first illustration as a `%Media{}` (or nil).
  """
  def build(my_poet \\ nil, today \\ Date.utc_today()) do
    my_id = my_poet && my_poet.id

    {public, private} =
      Poets.list_poets_on_the_road()
      |> Enum.reject(&(&1.id == my_id))
      |> Enum.split_with(& &1.is_public)

    ids = Enum.map(public, & &1.id)
    paths = path_points(ids)
    entries = published_entries(ids)
    {drawings, first_media} = illustrations(ids)
    places = Guide.count_published_places(ids)

    poets =
      Enum.map(public, fn poet ->
        poet_payload(
          poet,
          Map.get(paths, poet.id, []),
          Map.get(entries, poet.id, []),
          first_media,
          %{drawings: Map.get(drawings, poet.id, 0), places: Map.get(places, poet.id, 0)},
          today
        )
      end)

    %{
      me: me(my_poet),
      poets: poets,
      anonymous: Enum.map(private, &blurred_point/1),
      totals: totals(poets, private)
    }
  end

  @doc """
  What the map hook gets: the same shape with each stop's media reduced to
  its id, since the cards (and their source credits) are rendered server-side.
  """
  def tour_payload(%{poets: poets} = showcase) do
    %{
      showcase
      | poets:
          Enum.map(poets, fn poet ->
            %{poet | stops: Enum.map(poet.stops, &%{&1 | media: &1.media && &1.media.id})}
          end)
    }
  end

  @doc """
  A private poet contributes a pin and nothing else: no name, slug, avatar or
  place, and coordinates rounded to ~10km so the dot says "somewhere around
  here" rather than pointing at a street.
  """
  def blurred_point(poet) do
    %{lat: Float.round(poet.current_lat, 1), lng: Float.round(poet.current_lng, 1)}
  end

  defp me(%{current_lat: lat, current_lng: lng} = poet) when is_number(lat) and is_number(lng) do
    %{lat: lat, lng: lng, name: poet.current_place_name, poet: poet.name}
  end

  defp me(_), do: nil

  defp poet_payload(poet, path, entries, first_media, counts, today) do
    current = %{lat: poet.current_lat, lng: poet.current_lng, name: poet.current_place_name}

    countries =
      path
      |> Enum.map(& &1.country_code)
      |> Kernel.++([poet.current_country_code])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    stops =
      entries
      |> Enum.filter(&(is_number(&1.lat) and is_number(&1.lng)))
      |> Enum.take(-@stops_per_poet)
      |> Enum.map(fn entry ->
        %{
          lat: entry.lat,
          lng: entry.lng,
          place: entry.place_name,
          date: Date.to_iso8601(entry.entry_date),
          title: entry.title,
          media: Map.get(first_media, entry.id)
        }
      end)

    days =
      case entries do
        [first | _] -> Date.diff(today, first.entry_date) + 1
        [] -> 0
      end

    latest_url =
      case List.last(entries) do
        nil -> "/p/#{poet.slug}"
        entry -> "/p/#{poet.slug}/#{entry.entry_date}"
      end

    %{
      slug: poet.slug,
      name: poet.name,
      avatar: poet.avatar_url,
      mine: false,
      current: current,
      path: Enum.map(path, &%{lat: &1.lat, lng: &1.lng, name: &1.place_name}),
      stops: stops,
      countries: countries,
      stats: %{
        days: days,
        entries: length(entries),
        places: counts.places,
        countries: length(countries),
        drawings: counts.drawings
      },
      latest_url: latest_url
    }
  end

  defp totals(poets, private) do
    countries = poets |> Enum.flat_map(& &1.countries) |> Enum.uniq()

    %{
      poets: length(poets) + length(private),
      entries: poets |> Enum.map(& &1.stats.entries) |> Enum.sum(),
      places: poets |> Enum.map(& &1.stats.places) |> Enum.sum(),
      countries: length(countries),
      drawings: poets |> Enum.map(& &1.stats.drawings) |> Enum.sum()
    }
  end

  defp path_points([]), do: %{}

  defp path_points(ids) do
    PathPoint
    |> where([p], p.poet_id in ^ids)
    |> order_by(asc: :position)
    |> Repo.all()
    |> Enum.group_by(& &1.poet_id)
  end

  defp published_entries([]), do: %{}

  defp published_entries(ids) do
    Entry
    |> where([e], e.poet_id in ^ids and e.status == "published")
    |> order_by(asc: :entry_date)
    |> Repo.all()
    |> Enum.group_by(& &1.poet_id)
  end

  # Drawings on published entries: a count per poet, and the first one per
  # entry for the stops. One query for both.
  defp illustrations([]), do: {%{}, %{}}

  defp illustrations(ids) do
    rows =
      Media
      |> join(:inner, [m], e in Entry, on: e.id == m.journal_entry_id)
      |> where([m, e], e.poet_id in ^ids and e.status == "published" and m.kind == "illustration")
      |> order_by([m], asc: m.id)
      |> select([m, e], {e.poet_id, m})
      |> Repo.all()

    drawings = rows |> Enum.group_by(&elem(&1, 0)) |> Map.new(fn {id, r} -> {id, length(r)} end)

    first_media =
      Enum.reduce(rows, %{}, fn {_poet_id, media}, acc ->
        Map.put_new(acc, media.journal_entry_id, media)
      end)

    {drawings, first_media}
  end
end
