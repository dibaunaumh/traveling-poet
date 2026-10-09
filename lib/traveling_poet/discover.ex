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
  alias TravelingPoet.Journal.{Entry, Media, Section}
  alias TravelingPoet.Poets.Poet
  alias TravelingPoet.Spaces.{Ingest, Item}
  alias TravelingPoet.Topics.{Excursion, Find}

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
  merged by the shared item it was resolved to (Spaces, kb-002), by name
  and city for a row no item claims yet, keeping the newest row's id and
  every poet who found it.

      %{tree: PlaceTopics.tree(), places: [%{id, item_id, ids, name, city, country, ikind, starts, ends, topics, date, found_by}]}

  `ikind` is the kind of thing on the item side (place, event; a find's is
  idea, work, artwork, product), which the kind filter reads; `country` its
  ISO code through the admin hierarchy; `starts` and `ends` an event's
  dates on the time axis.

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
      |> Enum.group_by(fn r -> place_key(r.place, r.city) end)
      |> Enum.map(fn {_key, rows} ->
        # ISO strings, not %Date{}: tuples of structs compare field by field.
        newest = Enum.max_by(rows, fn r -> {Date.to_iso8601(r.date), r.place.id} end)

        %{
          id: newest.place.id,
          item_id: newest.place.item_id,
          name: newest.place.name,
          city: newest.city,
          ikind: newest.item_kind || place_kind(newest.place),
          country: newest.country,
          starts: iso(Enum.at(newest.item_time, 0) || newest.place.starts_on),
          ends: iso(Enum.at(newest.item_time, 1) || newest.place.ends_on),
          topics:
            rows
            |> Enum.flat_map(fn r -> [r.place.topic, r.place.second_topic | r.item_topics] end)
            |> Enum.reject(&is_nil/1)
            |> Enum.uniq(),
          date: Date.to_iso8601(newest.date),
          ids: Enum.map(rows, & &1.place.id),
          found_by: rows |> Enum.map(& &1.place.poet_id) |> Enum.uniq() |> length()
        }
      end)
      |> Enum.sort_by(&{&1.date, &1.id}, :desc)

    %{tree: PlaceTopics.tree(), places: places, finds: village_finds(ids)}
  end

  # What the poets brought back from days off the road (talks, papers,
  # exhibitions, recordings, books), on the same tree as the places. The same
  # find listed twice (a re-sent day, a second poet) is one tile, by name.
  defp village_finds([]), do: []

  defp village_finds(ids) do
    Find
    |> join(:inner, [f], e in Entry, on: e.id == f.journal_entry_id)
    |> join(:left, [f, _e], i in Item, on: i.id == f.item_id)
    |> where([f, e], f.poet_id in ^ids and e.status == "published")
    |> where([f, _e, i], not is_nil(f.topic) or not is_nil(i.topic))
    |> select([f, e, i], %{
      find: f,
      date: e.entry_date,
      item_topics: [i.topic, i.second_topic],
      item_kind: i.kind
    })
    |> Repo.all()
    |> Enum.group_by(fn r -> r.find.item_id || find_key(r.find.name) end)
    |> Enum.map(fn {_key, rows} ->
      newest = Enum.max_by(rows, fn r -> {Date.to_iso8601(r.date), r.find.id} end)

      %{
        id: newest.find.id,
        item_id: newest.find.item_id,
        name: newest.find.name,
        kind: newest.find.kind,
        ikind: newest.item_kind || Ingest.find_kind(newest.find.kind),
        topics:
          rows
          |> Enum.flat_map(fn r -> [r.find.topic, r.find.second_topic | r.item_topics] end)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq(),
        date: Date.to_iso8601(newest.date),
        found_by: rows |> Enum.map(& &1.find.poet_id) |> Enum.uniq() |> length()
      }
    end)
    |> Enum.sort_by(&{&1.date, &1.id}, :desc)
  end

  @doc """
  A find's overview: the find, the public poet who brought it back, the page
  and the destination it came from. nil unless the page is published and the
  poet public.
  """
  def find(id) do
    with {:ok, id} <- to_id(id),
         %Find{} = find <- Repo.get(Find, id),
         %Entry{status: "published"} = entry <- Repo.get(Entry, find.journal_entry_id),
         %Poet{} = poet <- public_poet(find.poet_id) do
      destination =
        Excursion
        |> where(journal_entry_id: ^entry.id)
        |> select([x], x.destination_name)
        |> Repo.one()

      %{find: find, poet: poet, entry: entry, destination: destination}
    else
      _ -> nil
    end
  end

  # The item a place was resolved to is the merge key: one row per real
  # place, however it was spelled and whichever poet wrote it. A row no item
  # claims yet (written before the Spaces backfill ran) merges by name and
  # city, as before.
  defp place_key(%Place{item_id: id}, _city) when is_integer(id), do: {:item, id}
  defp place_key(%Place{name: name}, city), do: {normalize(name), normalize(city)}

  # A find's name as a merge key: case, punctuation and spacing aside, so
  # "Atlas Fractured — Theo Eshetu" and "Atlas Fractured – Theo Eshetu" are
  # one find.
  defp find_key(name) do
    name
    |> normalize()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.trim()
  end

  defp normalize(nil), do: ""
  defp normalize(text), do: text |> String.downcase() |> String.trim()

  defp village_rows([]), do: []

  # A row sits in the village when it, or the item it is a visit of, has a
  # subject: one poet's row gets classified and every poet's row of the
  # same place follows.
  defp village_rows(ids) do
    Place
    |> join(:inner, [p], e in Entry, on: e.id == p.journal_entry_id)
    |> join(:left, [p, _e], i in Item, on: i.id == p.item_id)
    |> where([p, e], p.poet_id in ^ids and e.status == "published")
    |> where([p, _e, i], not is_nil(p.topic) or not is_nil(i.topic))
    |> select([p, e, i], %{
      place: p,
      city: e.place_name,
      date: e.entry_date,
      item_topics: [i.topic, i.second_topic],
      item_kind: i.kind,
      item_time: [i.time_start, i.time_end],
      country: i.country_code
    })
    |> Repo.all()
  end

  defp iso(nil), do: nil
  defp iso(%Date{} = date), do: Date.to_iso8601(date)

  # What a place row is on the item side before it has an item.
  defp place_kind(%Place{category: "event"}), do: "event"
  defp place_kind(_), do: "place"

  @doc """
  One public poet's visits of a kind, in the order they happened, for a
  route on the map:

      %{poet: %{slug, name}, kind, stops: [%{id, name, lat, lng, date, city}]}

  Mapped kinds only (place, event): works and ideas have no pins. nil
  unless the poet is public and on the road.
  """
  def journey(slug, kind) when is_binary(slug) and kind in ~w(place event) do
    with %Poet{} = poet <- Poets.get_public_poet_by_slug(slug),
         %Poet{} <- public_poet(poet.id) do
      stops =
        Place
        |> join(:inner, [p], e in Entry, on: e.id == p.journal_entry_id)
        |> join(:left, [p, _e], i in Item, on: i.id == p.item_id)
        |> where([p, e], p.poet_id == ^poet.id and e.status == "published")
        |> where([p], not is_nil(p.lat) and not is_nil(p.lng))
        |> where([p, _e, i], fragment("coalesce(?, ?)", i.kind, p.category) in ^kind_rows(kind))
        |> order_by([p], asc: p.entry_date, asc: p.position, asc: p.id)
        |> select([p, e], %{
          id: p.id,
          name: p.name,
          lat: p.lat,
          lng: p.lng,
          date: p.entry_date,
          city: e.place_name
        })
        |> Repo.all()
        |> Enum.map(&%{&1 | date: Date.to_iso8601(&1.date)})

      %{poet: %{slug: poet.slug, name: poet.name}, kind: kind, stops: stops}
    else
      _ -> nil
    end
  end

  def journey(_slug, _kind), do: nil

  # A row's kind is its item's, or, before it has one, its category: "event"
  # for an event and any other category for a place.
  defp kind_rows("event"), do: ["event"]
  defp kind_rows("place"), do: ["place" | Place.categories() -- ["event"]]

  # How many things of each kind a poet has published: places and events by
  # their item (or category), finds by their item (or kind).
  defp kind_counts(poet_id) do
    places =
      Place
      |> join(:inner, [p], e in Entry, on: e.id == p.journal_entry_id)
      |> join(:left, [p, _e], i in Item, on: i.id == p.item_id)
      |> where([p, e], p.poet_id == ^poet_id and e.status == "published")
      |> select([p, _e, i], {i.kind, p.category})
      |> Repo.all()
      |> Enum.map(fn {item_kind, category} ->
        item_kind || place_kind(%Place{category: category})
      end)

    finds =
      Find
      |> join(:inner, [f], e in Entry, on: e.id == f.journal_entry_id)
      |> join(:left, [f, _e], i in Item, on: i.id == f.item_id)
      |> where([f, e], f.poet_id == ^poet_id and e.status == "published")
      |> select([f, _e, i], {i.kind, f.kind})
      |> Repo.all()
      |> Enum.map(fn {item_kind, kind} -> item_kind || Ingest.find_kind(kind) end)

    Enum.frequencies(places ++ finds)
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
        also: also_found_by(place, entry, poet),
        related: related(place),
        # the item's public page, when the row has an item (always, after the backfill)
        item_slug: place.item_id && item_slug(place.item_id)
      }
    else
      _ -> nil
    end
  end

  defp item_slug(item_id) do
    Item
    |> where([i], i.id == ^item_id and i.status == "active")
    |> select([i], i.slug)
    |> Repo.one()
  end

  # What the poets linked to this place (Spaces links): a dish served here,
  # the festival it is part of, the artist who made it. Each with the public
  # place row that opens it, when one exists.
  defp related(%Place{item_id: nil}), do: []

  defp related(%Place{item_id: item_id}) do
    item_id
    |> TravelingPoet.Spaces.related()
    |> Enum.map(fn %{relation: relation, direction: direction, item: item} ->
      %{
        phrase: phrase(relation, direction),
        name: item.name,
        kind: item.kind,
        place_id: public_row_for(item.id)
      }
    end)
  end

  defp phrase("at", :out), do: "at"
  defp phrase("at", :in), do: "here:"
  defp phrase("part_of", :out), do: "part of"
  defp phrase("part_of", :in), do: "includes"
  defp phrase("made_by", :out), do: "made by"
  defp phrase("made_by", :in), do: "made"
  defp phrase("commemorates", :out), do: "commemorates"
  defp phrase("commemorates", :in), do: "remembered by"
  defp phrase("about", :out), do: "about"
  defp phrase("about", :in), do: "the subject of"
  defp phrase("series_of", :out), do: "a later edition of"
  defp phrase("series_of", :in), do: "returned as"
  defp phrase(relation, _), do: String.replace(relation, "_", " ")

  # The newest public, published place row of an item, to open it from a
  # related line. nil when every row is a private poet's or a find.
  defp public_row_for(item_id) do
    Place
    |> join(:inner, [p], e in Entry, on: e.id == p.journal_entry_id)
    |> join(:inner, [p, _e], po in Poet, on: po.id == p.poet_id)
    |> where([p, e, po], p.item_id == ^item_id and e.status == "published")
    |> where([_p, _e, po], po.is_public and po.status == "active")
    |> order_by([p], desc: p.id)
    |> limit(1)
    |> select([p], p.id)
    |> Repo.one()
  end

  # Other public poets who logged the same place: the ones whose rows point
  # at the same item, or, for a row no item claims, by name and city.
  defp also_found_by(%Place{item_id: id}, _entry, poet) when is_integer(id),
    do: TravelingPoet.Spaces.found_by(id, except: poet.id)

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
      # Every published page counts, pinned on the map or not: an excursion
      # day has no place, and the count is of pages, not of pins.
      entries =
        Repo.all(from e in Entry, where: e.poet_id == ^poet.id and e.status == "published")

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
          places: length(published_places([poet.id])),
          kinds: kind_counts(poet.id)
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

  # The page's drawing as the journal shows it: the one its illustration
  # section points to. Poets sometimes draw before the page exists, so the
  # media row was never linked to the entry (20 pages on prod by
  # 2026-09-25); the linked illustration is only the fallback.
  defp first_drawing(entry_id) do
    section_drawing =
      Section
      |> join(:inner, [s], m in Media, on: m.id == s.media_id)
      |> where([s], s.journal_entry_id == ^entry_id and s.kind == "illustration")
      |> order_by([s], asc: s.position)
      |> limit(1)
      |> select([_s, m], m)
      |> Repo.one()

    section_drawing ||
      Media
      |> where(journal_entry_id: ^entry_id, kind: "illustration")
      |> order_by(asc: :id)
      |> limit(1)
      |> Repo.one()
  end
end
