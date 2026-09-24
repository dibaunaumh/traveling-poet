defmodule TravelingPoet.Discover do
  @moduledoc """
  What anyone, signed in or not, can find across every poet's journey: the
  data behind `/discover`.

  Only public poets contribute entries and places. A private poet is a
  blurred dot (`blurred_point/1`) and nothing else: its
  entries and places are left out entirely, since a place pins down where
  its poet was just as well as a coordinate does.

  `build/1` is the map: every public poet, every published entry and place
  with coordinates, kept small (ids, names, points) because it all rides to
  the hook as JSON. The rich overview a click opens is loaded one item at a
  time by `entry/1`, `place/1` and `poet/1`, each re-checking that what was
  asked for is public and published, so a crafted id gets nothing.
  """

  import Ecto.Query

  alias TravelingPoet.{Poets, Repo}
  alias TravelingPoet.Guide.{Place, PlaceTopics}
  alias TravelingPoet.Journal.{Entry, Media}
  alias TravelingPoet.Poets.Poet

  # How many entries the tour turns through before it starts over. The map
  # shows every entry; the tour only the freshest pages.
  @rotation_size 30

  @doc """
  The whole map.

      %{
        poets: [%{slug, name, avatar, lat, lng, place}],
        entries: [%{id, poet, lat, lng, place, date, title}],
        places: [%{id, poet, lat, lng, name, group}],
        rotation: [entry_id],
        anonymous: [%{lat, lng}],
        totals: %{poets, entries, places}
      }

  `poet` on an entry or place is its poet's slug.
  """
  def build do
    {public, private} = Poets.list_poets_on_the_road() |> Enum.split_with(& &1.is_public)
    ids = Enum.map(public, & &1.id)
    slugs = Map.new(public, &{&1.id, &1.slug})

    entries =
      published_entries(ids)
      |> Enum.map(fn e ->
        %{
          id: e.id,
          poet: slugs[e.poet_id],
          lat: e.lat,
          lng: e.lng,
          place: e.place_name,
          date: Date.to_iso8601(e.entry_date),
          title: e.title
        }
      end)

    places =
      published_places(ids)
      |> Enum.map(fn p ->
        %{
          id: p.id,
          poet: slugs[p.poet_id],
          lat: p.lat,
          lng: p.lng,
          name: p.name,
          group: Place.group_for(p.category)
        }
      end)

    %{
      poets:
        Enum.map(public, fn p ->
          %{
            slug: p.slug,
            name: p.name,
            avatar: p.avatar_url,
            lat: p.current_lat,
            lng: p.current_lng,
            place: p.current_place_name
          }
        end),
      entries: entries,
      places: places,
      rotation: rotation(entries),
      anonymous: Enum.map(private, &blurred_point/1),
      totals: %{
        poets: length(public) + length(private),
        entries: length(entries),
        places: length(places)
      }
    }
  end

  @doc """
  What the map hook is sent: `build/0` with only the fields it draws, and
  coordinates rounded to four places (about 10 m). Everything else stays on
  the server: the overview a click opens is loaded one item at a time, and
  the village list only when someone opens the village (`village/0`).

  Sent by the hook's own request once it is connected, never as a page
  attribute: an attribute is HTML-escaped (every quote becomes &quot;) and
  LiveView sends it twice, in the page and again when the socket joins.
  """
  def client_payload(discover) do
    %{
      poets: Enum.map(discover.poets, &(Map.take(&1, [:slug, :name]) |> Map.merge(point(&1)))),
      entries:
        Enum.map(discover.entries, fn e ->
          %{id: e.id, title: e.title || e.place} |> Map.merge(point(e))
        end),
      places:
        Enum.map(discover.places, &(Map.take(&1, [:id, :name, :group]) |> Map.merge(point(&1)))),
      rotation: discover.rotation,
      anonymous: discover.anonymous,
      me: Map.get(discover, :me)
    }
  end

  defp point(%{lat: lat, lng: lng}), do: %{lat: round4(lat), lng: round4(lng)}

  defp round4(n) when is_float(n), do: Float.round(n, 4)
  defp round4(n), do: n

  @doc """
  The global village: every public poet's published places that carry a
  topic, mapped or not (a place needs no coordinates to sit in a subject),
  one per place. The same place logged again (another day, another poet) is
  merged by name and city, keeping the newest row's id and every poet who
  found it.

      %{tree: PlaceTopics.tree(), places: [%{id, ids, name, city, topics, date, found_by}]}

  `ids` are every row merged into the place, so the world map can show the
  places under a subject; `found_by` is how many poets logged it.

  `topics` are third-level paths (Guide.PlaceTopics); a place under two
  subjects appears under both. Newest first.
  """
  def village do
    ids =
      Poets.list_poets_on_the_road()
      |> Enum.filter(& &1.is_public)
      |> Enum.map(& &1.id)

    places =
      village_rows(ids)
      |> Enum.group_by(fn {p, city, _date} -> {normalize(p.name), normalize(city)} end)
      |> Enum.map(fn {_key, rows} ->
        # ISO strings, not %Date{}: tuples of structs compare field by field.
        {newest, city, date} = Enum.max_by(rows, fn {p, _c, d} -> {Date.to_iso8601(d), p.id} end)

        %{
          id: newest.id,
          name: newest.name,
          city: city,
          topics:
            rows
            |> Enum.flat_map(fn {p, _, _} -> [p.topic, p.second_topic] end)
            |> Enum.reject(&is_nil/1)
            |> Enum.uniq(),
          date: Date.to_iso8601(date),
          ids: Enum.map(rows, fn {p, _, _} -> p.id end),
          found_by: rows |> Enum.map(fn {p, _, _} -> p.poet_id end) |> Enum.uniq() |> length()
        }
      end)
      |> Enum.sort_by(&{&1.date, &1.id}, :desc)

    %{tree: PlaceTopics.tree(), places: places}
  end

  defp normalize(nil), do: ""
  defp normalize(text), do: text |> String.downcase() |> String.trim()

  defp village_rows([]), do: []

  defp village_rows(ids) do
    Place
    |> join(:inner, [p], e in Entry, on: e.id == p.journal_entry_id)
    |> where([p, e], p.poet_id in ^ids and e.status == "published" and not is_nil(p.topic))
    |> select([p, e], {p, e.place_name, e.entry_date})
    |> Repo.all()
  end

  @doc """
  The one rule for how a private poet appears on any map: a pin and nothing
  else. No name, slug, avatar or place, and coordinates rounded to ~10km so
  the dot says "somewhere around here" rather than pointing at a street.
  """
  def blurred_point(poet) do
    %{lat: Float.round(poet.current_lat, 1), lng: Float.round(poet.current_lng, 1)}
  end

  @doc """
  The order the tour turns the pages in: newest first, one entry per poet per
  round, so a poet who writes every day cannot crowd out one who writes
  twice a week. Round one is every poet's newest page, newest of those first;
  round two every poet's second newest, and so on. Capped at #{@rotation_size}.
  """
  def rotation(entries) do
    entries
    |> Enum.group_by(& &1.poet)
    |> Enum.flat_map(fn {_poet, own} ->
      own
      |> Enum.sort_by(&{&1.date, &1.id}, :desc)
      |> Enum.with_index(fn e, round -> {round, e} end)
    end)
    |> Enum.sort_by(fn {round, e} -> {-round, e.date, e.id} end, :desc)
    |> Enum.take(@rotation_size)
    |> Enum.map(fn {_round, e} -> e.id end)
  end

  @doc """
  One entry's overview: the entry, its public poet and its first drawing
  (a `%Media{}` or nil). nil unless the entry is published and its poet is
  public and on the road.
  """
  def entry(id) do
    with {:ok, id} <- to_id(id),
         %Entry{status: "published"} = entry <- Repo.get(Entry, id),
         %Poet{} = poet <- public_poet(entry.poet_id) do
      %{entry: entry, poet: poet, drawing: first_drawing(entry.id)}
    else
      _ -> nil
    end
  end

  @doc """
  One place's overview: the place, its poet, its drawing (a `%Media{}` or
  nil) and `also`, the other public poets who logged the same place (same
  name, same city). nil unless the place came from a published entry of a
  public poet.

  Only a handful of places have a drawing of their own, so without one the
  overview borrows the first drawing of the page the place came from
  (`drawing_from: :entry`), which the overview credits as such.
  """
  def place(id) do
    with {:ok, id} <- to_id(id),
         %Place{} = place <- Repo.get(Place, id),
         %Entry{status: "published"} = entry <-
           place.journal_entry_id && Repo.get(Entry, place.journal_entry_id),
         %Poet{} = poet <- public_poet(place.poet_id) do
      {drawing, from} =
        case place.media_id && Repo.get(Media, place.media_id) do
          %Media{} = media -> {media, :place}
          nil -> {first_drawing(entry.id), :entry}
        end

      %{
        place: place,
        poet: poet,
        entry: entry,
        drawing: drawing,
        drawing_from: drawing && from,
        also: also_found_by(place, entry, poet)
      }
    else
      _ -> nil
    end
  end

  # Other public poets who logged the same place, by name and city.
  defp also_found_by(place, entry, poet) do
    name = normalize(place.name)
    city = normalize(entry.place_name)

    Place
    |> join(:inner, [p], e in Entry, on: e.id == p.journal_entry_id)
    |> join(:inner, [p, _e], po in Poet, on: po.id == p.poet_id)
    |> where([p, e, po], e.status == "published" and po.is_public and po.status == "active")
    |> where([p, _e, po], po.id != ^poet.id and fragment("lower(trim(?))", p.name) == ^name)
    |> where([_p, e], fragment("lower(trim(coalesce(?, '')))", e.place_name) == ^city)
    |> select([_p, _e, po], po)
    |> distinct(true)
    |> Repo.all()
  end

  @doc """
  One poet's overview: the poet, a few numbers, and its newest published
  entry. nil unless the poet is public and on the road.
  """
  def poet(slug, today \\ Date.utc_today()) when is_binary(slug) do
    with %Poet{} = poet <- Poets.get_public_poet_by_slug(slug),
         %Poet{} <- public_poet(poet.id) do
      entries = published_entries([poet.id])

      days =
        case entries do
          [] -> 0
          _ -> Date.diff(today, entries |> Enum.map(& &1.entry_date) |> Enum.min(Date)) + 1
        end

      %{
        poet: poet,
        latest: Enum.max_by(entries, & &1.entry_date, Date, fn -> nil end),
        stats: %{
          days: days,
          entries: length(entries),
          places: length(published_places([poet.id]))
        }
      }
    else
      _ -> nil
    end
  end

  # Public, active and with a position: the same poets the map shows.
  defp public_poet(id) do
    case Repo.get(Poet, id) do
      %Poet{is_public: true, status: "active", current_lat: lat} = poet when is_number(lat) ->
        poet

      _ ->
        nil
    end
  end

  defp to_id(id) when is_integer(id), do: {:ok, id}

  defp to_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp to_id(_), do: :error

  defp published_entries([]), do: []

  defp published_entries(ids) do
    Entry
    |> where([e], e.poet_id in ^ids and e.status == "published")
    |> where([e], not is_nil(e.lat) and not is_nil(e.lng))
    |> order_by(asc: :entry_date)
    |> Repo.all()
  end

  defp published_places([]), do: []

  defp published_places(ids) do
    Place
    |> join(:inner, [p], e in Entry, on: e.id == p.journal_entry_id)
    |> where([p, e], p.poet_id in ^ids and e.status == "published")
    |> where([p], not is_nil(p.lat) and not is_nil(p.lng))
    |> order_by([p], asc: p.id)
    |> Repo.all()
  end

  defp first_drawing(entry_id) do
    Media
    |> where(journal_entry_id: ^entry_id, kind: "illustration")
    |> order_by(asc: :id)
    |> limit(1)
    |> Repo.one()
  end
end
