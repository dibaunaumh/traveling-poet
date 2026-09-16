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

  ## One place, once per stay

  @doc """
  What two place names have in common when they name the same place: no
  accents, no case, no punctuation. Rafi logged "Dylan's Cafe" on one day
  and "Dylan's Café" the next.
  """
  def name_key(name) when is_binary(name) do
    name
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
    # "Dylan's" and "Dylans" are one name; an apostrophe is not a word break
    |> String.replace(~r/['\x{2019}\x{2018}`]/u, "")
    |> String.replace(~r/[^a-z0-9]+/, " ")
    |> String.trim()
  end

  def name_key(_), do: ""

  @doc """
  Places published on earlier days of the stay this entry belongs to. Each
  daily run is a fresh session with no memory of yesterday, so on day two
  the poet found the same good cafe and logged it again: 68 of 737 places
  across the fleet had been, events included. These are what an entry may
  not repeat.
  """
  def logged_earlier_in_stay(%Entry{} = entry) do
    case path_point_for(entry) do
      nil ->
        []

      stay_id ->
        entry.poet_id
        |> list_places(path_point_id: stay_id)
        |> Enum.filter(&(Date.compare(&1.entry_date, entry.entry_date) == :lt))
    end
  end

  @doc """
  What the poet is told each morning: the places it already logged at the
  place it is staying, before today. Empty on the day it arrives somewhere
  new (and read before a move, it describes the stay being left).
  """
  def this_stay_payload(poet_id, today \\ Date.utc_today()) do
    case TravelingPoet.Poets.current_path_point(poet_id) do
      nil ->
        []

      stay ->
        poet_id
        |> list_places(path_point_id: stay.id)
        |> Enum.filter(&(Date.compare(&1.entry_date, today) == :lt))
        |> dedupe_by_name()
        |> Enum.map(&%{name: &1.name, category: &1.category, logged_on: &1.entry_date})
    end
  end

  @doc "Keeps the first place of each name (by `name_key/1`), in order."
  def dedupe_by_name(places), do: Enum.uniq_by(places, &name_key(&1.name))

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
  def path_point_for(%Entry{poet_id: poet_id} = entry) do
    stays =
      PathPoint
      |> where(poet_id: ^poet_id)
      |> order_by(asc: :position)
      |> Repo.all()

    path_point_for(entry, stays)
  end

  @doc """
  The same rule, pure: `stays` is the poet's path in position order, loaded
  once. The book assigns every entry of a journey to its chapter this way
  without a query per entry.
  """
  def path_point_for(%{entry_date: date} = entry, stays) when is_list(stays) do
    started = stays |> Enum.filter(&started_by?(&1, date)) |> List.last()

    covering =
      stays
      |> Enum.filter(&covers?(&1, date))
      |> best_covering(entry)

    case covering || started || List.first(stays) do
      nil -> nil
      pp -> pp.id
    end
  end

  # On a day the poet travelled, TWO stays cover the date -- covers?/2 compares
  # dates, not timestamps, so the one departed at 00:32 and the one arrived at
  # 00:32 both match. Taking the earlier one was wrong: SKILL.md's first rule
  # is "travel first, then write", so the entry is about the place moved TO.
  #
  # Observed on poet E, whose onboarding left a five-minute Fez path point
  # before it moved to Louisville. A day of Louisville places landed under a
  # "Fez, Morocco" tab, and the map dutifully showed Louisville pins there.
  #
  # The entry's own place_name is the authoritative statement of what it is
  # about, so it wins when it matches; otherwise the latest arrival does.
  defp best_covering([], _entry), do: nil
  defp best_covering([only], _entry), do: only

  defp best_covering(stays, %{place_name: place_name}) do
    Enum.find(stays, &same_place?(&1.place_name, place_name)) || List.last(stays)
  end

  defp best_covering(stays, _entry), do: List.last(stays)

  defp same_place?(a, b) when is_binary(a) and is_binary(b) do
    String.downcase(String.trim(a)) == String.downcase(String.trim(b))
  end

  defp same_place?(_, _), do: false

  @doc """
  Recomputes which stay each of a poet's places belongs to.

  A repair for places already written under the wrong stay; the attribution is
  derived, so nothing is lost by recomputing it.
  """
  def reassign_stays(poet_id) do
    Place
    |> where(poet_id: ^poet_id)
    |> Repo.all()
    |> Enum.group_by(& &1.journal_entry_id)
    |> Enum.reduce(0, fn {entry_id, places}, moved ->
      case Repo.get(Entry, entry_id) do
        nil ->
          moved

        entry ->
          correct = path_point_for(entry)
          wrong = Enum.reject(places, &(&1.path_point_id == correct))

          Enum.each(wrong, fn place ->
            place |> Place.changeset(%{path_point_id: correct}) |> Repo.update()
          end)

          moved + length(wrong)
      end
    end)
  end

  # Stays are matched on their fields, not the struct, so the pure form works
  # on bare maps in tests and builders too.
  defp started_by?(%{arrived_at: nil}, _date), do: false

  defp started_by?(%{arrived_at: arrived}, date),
    do: Date.compare(DateTime.to_date(arrived), date) != :gt

  defp covers?(%{arrived_at: nil}, _date), do: false

  defp covers?(%{arrived_at: arrived, departed_at: departed}, date) do
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

  @doc "`list_places_for_entry/1` for many entries: `%{entry_id => [place]}`, one query."
  def list_places_for_entries([]), do: %{}

  def list_places_for_entries(entry_ids) do
    Place
    |> where([p], p.journal_entry_id in ^entry_ids)
    |> order_by(asc: :position)
    |> Repo.all()
    |> Enum.group_by(& &1.journal_entry_id)
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

  @doc "Published places per poet, for the fleet showcase: `%{poet_id => count}`."
  def count_published_places([]), do: %{}

  def count_published_places(poet_ids) do
    Place
    |> maybe_published(true)
    |> where([p], p.poet_id in ^poet_ids)
    |> group_by([p], p.poet_id)
    |> select([p], {p.poet_id, count(p.id)})
    |> Repo.all()
    |> Map.new()
  end

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

  @doc """
  The queries to try against Nominatim for a place, best first.

  Nominatim's free-text search is over-specification-sensitive: joining the
  venue name, its full postal address AND the city produces a string it
  matches nothing against. Observed in production on 2026-09-01, where all
  three of Matti's Vienna places failed with perfectly good addresses:

      "Cafe Museum, Operngasse 7, 1010 Vienna, Austria, Vienna, Austria" -> 0 hits
      "Operngasse 7, 1010 Vienna, Austria"                              -> 3 hits
      "Cafe Museum, Vienna, Austria"                                    -> 2 hits

  So: the address alone is the best query (it already carries the city, and
  only gets one appended when it doesn't). The name plus city is the fallback,
  which is also the only option for a place the poet gave no address.
  """
  def geocode_queries(%Place{} = place, city) do
    [address_query(place, city), name_query(place, city)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp address_query(%Place{address: address}, city) do
    case present(address) do
      nil -> nil
      address -> if mentions_city?(address, city), do: address, else: join([address, city])
    end
  end

  defp name_query(%Place{name: name}, city), do: join([present(name), city])

  # City is typically "Vienna, Austria"; an address that already names the town
  # must not have it appended again.
  defp mentions_city?(address, city) do
    case present(city) do
      nil ->
        true

      city ->
        town = city |> String.split(",") |> hd() |> String.trim() |> String.downcase()
        town != "" and String.contains?(String.downcase(address), town)
    end
  end

  defp join(parts) do
    parts |> Enum.map(&present/1) |> Enum.reject(&is_nil/1) |> Enum.join(", ")
  end

  defp present(nil), do: nil

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_), do: nil

  @doc """
  Flips failed geocodes back to pending so the drain retries them.

  For use after a geocoder fix: a place marked failed by a bug of ours is not
  a place that does not exist, and without this the only record of that is a
  row nothing will ever look at again.
  """
  def reset_failed_geocodes(poet_id) do
    from(p in Place, where: p.poet_id == ^poet_id and p.geocode_status == "failed")
    |> Repo.update_all(set: [geocode_status: "pending", updated_at: DateTime.utc_now()])
  end
end
