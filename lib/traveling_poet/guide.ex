defmodule TravelingPoet.Guide do
  @moduledoc """
  The Trip Guide: the concrete places a poet found, as structured data.

  Its own context rather than part of `Journal` because it has a different
  writer (the agent's places endpoint and the backfill task), a different
  reader (GuideLive), and an external dependency (the geocoder) that has no
  business inside entry rendering.

  IMPORTANT, if you are ever tempted to fold places into `journal_sections`:
  don't. `Journal.replace_sections/2` wipes sections wholesale, and
  travel-and-journal/SKILL.md tells the poet to re-send its full section list
  after illustrating. Places carried in that list would lose their geocoded
  coordinates and their drawings on every re-put.
  """

  import Ecto.Query

  alias TravelingPoet.Repo
  alias TravelingPoet.Guide.Place
  alias TravelingPoet.Journal.Entry
  alias TravelingPoet.Poets.PathPoint

  @filter_groups ~w(all food sights events)

  def filter_groups, do: @filter_groups

  ## Writing

  @doc """
  Replaces an entry's places wholesale -- the agent sends the full list for a
  day, exactly like `Journal.replace_sections/2`.

  Coordinates and drawings are PRESERVED across the replace when a place keeps
  its name. Both cost real resources to produce (an OSM request against a
  1 req/s budget; one of six daily image slots), and the skill has the poet
  re-sending its list within the same run, so re-spending them would be pure
  waste.
  """
  def replace_places(%Entry{} = entry, places_attrs) when is_list(places_attrs) do
    kept = preserved_by_name(entry.id)
    path_point_id = path_point_for(entry)

    Repo.transaction(fn ->
      Repo.delete_all(from(p in Place, where: p.journal_entry_id == ^entry.id))

      places_attrs
      |> Enum.with_index()
      |> Enum.map(fn {attrs, i} ->
        attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
        name = attrs |> Map.get("name", "") |> to_string() |> String.trim()

        %Place{}
        |> Place.changeset(
          attrs
          |> Map.merge(Map.get(kept, name, %{}))
          |> Map.put("poet_id", entry.poet_id)
          |> Map.put("journal_entry_id", entry.id)
          |> Map.put("path_point_id", path_point_id)
          |> Map.put("entry_date", entry.entry_date)
          |> Map.put("position", i)
        )
        |> Repo.insert!()
      end)
    end)
  end

  # What survives a wholesale replace, keyed by place name.
  defp preserved_by_name(entry_id) do
    Place
    |> where(journal_entry_id: ^entry_id)
    |> Repo.all()
    |> Map.new(fn p ->
      kept =
        %{
          "lat" => p.lat,
          "lng" => p.lng,
          "geocode_status" => p.geocode_status,
          "media_id" => p.media_id
        }
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()

      {p.name, kept}
    end)
  end

  @doc """
  The stay an entry belongs to.

  Prefers the path point whose arrival/departure window covers the date. Falls
  back to the most recent stay that had already started, and then to the
  earliest stay on record -- which is what makes the backfill useful: entries
  written before the poet's path was being tracked predate every arrived_at,
  and would otherwise all land outside every stay and give the guide no city
  grouping at all.

  Nil is still a valid answer (a poet with no path points yet). It costs only
  the grouping, never the place.
  """
  def path_point_for(%Entry{poet_id: poet_id, entry_date: date}) do
    stays =
      PathPoint
      |> where(poet_id: ^poet_id)
      |> order_by(asc: :position)
      |> Repo.all()

    covering = Enum.find(stays, &covers?(&1, date))
    started = stays |> Enum.filter(&started_by?(&1, date)) |> List.last()

    case covering || started || List.first(stays) do
      nil -> nil
      pp -> pp.id
    end
  end

  defp started_by?(%PathPoint{arrived_at: nil}, _date), do: false

  defp started_by?(%PathPoint{arrived_at: arrived}, date),
    do: Date.compare(DateTime.to_date(arrived), date) != :gt

  defp covers?(%PathPoint{arrived_at: nil}, _date), do: false

  defp covers?(%PathPoint{arrived_at: arrived, departed_at: departed}, date) do
    Date.compare(DateTime.to_date(arrived), date) != :gt and
      (is_nil(departed) or Date.compare(DateTime.to_date(departed), date) != :lt)
  end

  def attach_media(%Place{} = place, media_id) do
    place |> Place.changeset(%{media_id: media_id}) |> Repo.update()
  end

  def get_place(poet_id, id), do: Repo.get_by(Place, id: id, poet_id: poet_id)

  def list_places_for_entry(entry_id) do
    Place |> where(journal_entry_id: ^entry_id) |> order_by(asc: :position) |> Repo.all()
  end

  ## Reading

  @doc """
  Places for a poet's guide.

  `published_only` defaults to TRUE: a draft entry's places must never reach a
  reader, and the owner's view is what opts in.
  """
  def list_places(poet_id, opts \\ []) do
    published_only = Keyword.get(opts, :published_only, true)

    Place
    |> where(poet_id: ^poet_id)
    |> maybe_published(published_only)
    |> maybe_stay(Keyword.get(opts, :path_point_id, :any))
    |> maybe_group(Keyword.get(opts, :group, "all"))
    |> order_by(asc: :entry_date, asc: :position)
    |> Repo.all()
  end

  defp maybe_published(query, false), do: query

  defp maybe_published(query, true) do
    join(query, :inner, [p], e in Entry,
      on: e.id == p.journal_entry_id and e.status == "published"
    )
  end

  defp maybe_stay(query, :any), do: query
  defp maybe_stay(query, nil), do: where(query, [p], is_nil(p.path_point_id))
  defp maybe_stay(query, id), do: where(query, [p], p.path_point_id == ^id)

  defp maybe_group(query, group) when group in [nil, "all"], do: query

  defp maybe_group(query, "food"),
    do: where(query, [p], p.category in ^~w(restaurant cafe))

  defp maybe_group(query, "events"), do: where(query, [p], p.category == "event")

  defp maybe_group(query, "sights"),
    do: where(query, [p], p.category not in ^~w(restaurant cafe event))

  defp maybe_group(query, _), do: query

  @doc "Counts per filter chip, so a chip can show how much it would reveal."
  def counts_by_group(places) do
    base = %{"all" => length(places), "food" => 0, "sights" => 0, "events" => 0}

    Enum.reduce(places, base, fn place, acc ->
      Map.update!(acc, Place.group_for(place.category), &(&1 + 1))
    end)
  end

  @doc """
  The stays that actually have places, newest first -- the city switcher.
  """
  def list_stays(poet_id) do
    stay_ids =
      Place
      |> where(poet_id: ^poet_id)
      |> where([p], not is_nil(p.path_point_id))
      |> select([p], p.path_point_id)
      |> distinct(true)
      |> Repo.all()

    PathPoint
    |> where(poet_id: ^poet_id)
    |> where([pp], pp.id in ^stay_ids)
    |> order_by(desc: :position)
    |> Repo.all()
  end

  @doc """
  Groups places into the Itinerary view's days.

  Day N is the Nth DISTINCT DATE that produced places within this stay, not
  `Date.diff` against an arrival. A poet that skipped a day should show
  "Day 1, Day 2, Day 3", not a hole where Day 3 would be -- and `arrived_at`
  on the poet record is reset by every `Poets.move_to/2`, so it cannot number
  a trip at all.
  """
  def group_by_day(places) do
    dates = places |> Enum.map(& &1.entry_date) |> Enum.uniq() |> Enum.sort(Date)
    numbers = dates |> Enum.with_index(1) |> Map.new(fn {d, i} -> {d, i} end)

    places
    |> Enum.group_by(& &1.entry_date)
    |> Enum.sort_by(fn {date, _} -> date end, Date)
    |> Enum.map(fn {date, day_places} ->
      %{
        day: Map.fetch!(numbers, date),
        date: date,
        places: Enum.sort_by(day_places, & &1.position)
      }
    end)
  end

  @doc """
  The JSON the map hook consumes. Only geocoded places -- everything else is
  still listed elsewhere, it simply has no pin.
  """
  def map_payload(places, poet_name) do
    places
    |> Enum.filter(&Place.mapped?/1)
    |> Enum.with_index(1)
    |> Enum.map(fn {p, n} ->
      %{
        id: p.id,
        n: n,
        lat: p.lat,
        lng: p.lng,
        name: p.name,
        category: p.category,
        group: Place.group_for(p.category),
        rating: p.poet_rating,
        blurb: p.blurb,
        url: p.source_url,
        poet: poet_name
      }
    end)
  end

  def unmapped_count(places), do: Enum.count(places, &(not Place.mapped?(&1)))

  ## Geocoding lifecycle

  def pending_geocodes(limit \\ 50) do
    Place
    |> where(geocode_status: "pending")
    |> order_by(asc: :id)
    |> limit(^limit)
    |> Repo.all()
  end

  def update_geocode(%Place{} = place, %{lat: lat, lng: lng}) when is_number(lat) do
    place
    |> Place.changeset(%{lat: lat, lng: lng, geocode_status: "ok"})
    |> Repo.update()
  end

  def update_geocode(%Place{} = place, _), do: mark_geocode_failed(place)

  def mark_geocode_failed(%Place{} = place) do
    place |> Place.changeset(%{geocode_status: "failed"}) |> Repo.update()
  end

  @doc "The string handed to Nominatim for a place."
  def geocode_query(%Place{} = place, city) do
    [place.name, place.address, city]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
    |> Enum.join(", ")
  end
end
