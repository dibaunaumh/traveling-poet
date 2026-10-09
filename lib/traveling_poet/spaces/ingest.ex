defmodule TravelingPoet.Spaces.Ingest do
  @moduledoc """
  Points every per-poet row at the item it is a visit of (kb-002), as the row
  is written: places, finds and stay areas after a put, a path point after
  a move, and the item's own coordinates whenever a visit learns something
  the item lacks (a pin from the geocoder, a subject from the classifier).

  Never fails a write. Resolution is a convenience layered on the poet's
  data; a resolver error is logged and the row is saved without an item,
  for the backfill to pick up.

  Candidates come from the same kind: the same normalised name, the same
  city, or a pin inside a small box around the probe's. `Spaces.Resolver`
  decides; this module only fetches, creates and links.
  """

  require Logger
  import Ecto.Query

  alias TravelingPoet.{Repo, Spaces}
  alias TravelingPoet.Guide.{Place, StayArea}
  alias TravelingPoet.Journal.Entry
  alias TravelingPoet.Poets.PathPoint
  alias TravelingPoet.Spaces.{Hierarchy, Item, ItemReview, Link, Resolver}
  alias TravelingPoet.Topics.Find

  # Roughly 1.2 km of latitude; the box only narrows the candidate set,
  # the resolver measures the real distance.
  @box_deg 0.011
  # The admin hierarchy's subkinds (Spaces.Hierarchy): never a match for an
  # ordinary place of the same name.
  @admin ~w(city region country)
  @city_box_deg 0.15

  ## Places

  @doc "Resolves an entry's places (just written) to items. Returns the places, item ids set."
  def sync_places(%Entry{} = entry, places) when is_list(places) do
    Enum.map(places, &sync_place(entry, &1))
  end

  defp sync_place(entry, %Place{} = place) do
    safely(place, fn ->
      probe = place_probe(entry, place)
      item = resolve_or_create(probe, place.poet_id)
      item = refresh(item, probe)
      place |> Ecto.Changeset.change(item_id: item.id) |> Repo.update!()
    end)
  end

  defp place_probe(entry, %Place{} = place) do
    {kind, subkind} =
      case {place.kind, place.category} do
        {kind, _} when is_binary(kind) -> {kind, nil}
        {_, "event"} -> {"event", nil}
        {_, category} -> {"place", place.place_type || category}
      end

    %{
      kind: kind,
      subkind: subkind,
      name: place.name,
      norm_name: Resolver.name_key(place.name),
      city: entry.place_name,
      lat: if(place.geocode_status == "ok", do: place.lat),
      lng: if(place.geocode_status == "ok", do: place.lng),
      source_url: place.source_url,
      topic: place.topic,
      second_topic: place.second_topic,
      topics_classified_at: place.topics_classified_at,
      time_start: place.starts_on,
      time_end: place.ends_on,
      era: place.era,
      parent_id: stay_item_id(place.path_point_id),
      country_code: stay_country(place.path_point_id)
    }
  end

  @doc "A place just got its pin: the item takes it when it has none."
  def place_geocoded(%Place{item_id: nil}), do: :ok

  def place_geocoded(%Place{} = place) do
    safely(:ok, fn ->
      case Repo.get(Item, place.item_id) do
        %Item{lat: nil} = item when is_number(place.lat) ->
          item
          |> Item.changeset(%{lat: place.lat, lng: place.lng, geocode_status: "ok"})
          |> Repo.update!()

          :ok

        _ ->
          :ok
      end
    end)
  end

  @doc "A place or find was put on the subject tree: the item takes the topics when it has none."
  def topics_tagged(%{item_id: nil}), do: :ok

  def topics_tagged(%{item_id: item_id} = row) do
    safely(:ok, fn ->
      case Repo.get(Item, item_id) do
        %Item{topic: nil} = item when is_binary(row.topic) ->
          item
          |> Item.changeset(%{
            topic: row.topic,
            second_topic: row.second_topic,
            topics_classified_at: row.topics_classified_at
          })
          |> Repo.update!()

          :ok

        _ ->
          :ok
      end
    end)
  end

  ## Finds

  @doc "Resolves an entry's finds (just written) to items."
  def sync_finds(%Entry{} = entry, finds) when is_list(finds) do
    Enum.map(finds, &sync_find(entry, &1))
  end

  defp sync_find(_entry, %Find{} = find) do
    safely(find, fn ->
      probe = find_probe(find)
      item = resolve_or_create(probe, find.poet_id)
      item = refresh(item, probe)
      find |> Ecto.Changeset.change(item_id: item.id) |> Repo.update!()
    end)
  end

  @doc "A find's kind on the item side: talks and papers are ideas, books and films works."
  def find_kind(kind) when kind in ~w(talk paper session), do: "idea"
  def find_kind("product"), do: "product"
  def find_kind("artwork"), do: "artwork"
  def find_kind(kind) when kind in ~w(music book screen), do: "work"
  def find_kind(kind) when kind in ~w(event outing), do: "event"
  def find_kind("venue"), do: "place"
  def find_kind("person"), do: "person"
  def find_kind("dish"), do: "dish"
  def find_kind(_), do: "other"

  defp find_probe(%Find{} = find) do
    %{
      kind: find_kind(find.kind),
      subkind: find.kind,
      name: find.name,
      norm_name: Resolver.name_key(find.name),
      city: nil,
      lat: nil,
      lng: nil,
      source_url: find.url,
      topic: find.topic,
      second_topic: find.second_topic,
      topics_classified_at: find.topics_classified_at,
      time_start: nil,
      time_end: nil,
      parent_id: nil,
      country_code: nil
    }
  end

  ## Stay areas

  @doc "Resolves an entry's stay areas (written and located) to items."
  def sync_areas(%Entry{} = entry, areas) when is_list(areas) do
    Enum.map(areas, &sync_area(entry, &1))
  end

  defp sync_area(_entry, %StayArea{} = area) do
    safely(area, fn ->
      probe = %{
        kind: "place",
        subkind: "neighbourhood",
        name: area.name,
        norm_name: Resolver.name_key(area.name),
        city: area.city,
        lat: if(area.geocode_status == "ok", do: area.lat),
        lng: if(area.geocode_status == "ok", do: area.lng),
        source_url: nil,
        topic: nil,
        second_topic: nil,
        topics_classified_at: nil,
        time_start: nil,
        time_end: nil,
        parent_id: city_item_id(area.city),
        country_code: nil
      }

      probe = %{
        probe
        | country_code:
            Hierarchy.country_code_of(probe.parent_id && Repo.get(Item, probe.parent_id))
      }

      item = resolve_or_create(probe, area.poet_id)
      item = refresh(item, probe)
      area |> Ecto.Changeset.change(item_id: item.id) |> Repo.update!()
    end)
  end

  ## Links the poet reported

  @poet_relations ~w(at part_of made_by commemorates about)

  @doc """
  The links a put carried (Spaces phase 2): each row's `links`, a list of
  `%{"relation", "target"}` where the target is the name of another row
  in the same list, or of something the app already knows in the same
  city. The entry's earlier poet links are replaced, as the rows are. A
  target nothing matches is reported back, never invented: a link is only
  ever between things a poet reported.

  A dish `at` a restaurant takes the restaurant's pin when it has none.

  Returns `%{made: n, unknown: [target]}`.
  """
  def sync_links(%Entry{} = entry, rows, attrs_list) when is_list(rows) and is_list(attrs_list) do
    safely(%{made: 0, unknown: []}, fn ->
      Repo.delete_all(
        from(l in Link, where: l.journal_entry_id == ^entry.id and l.source == "poet")
      )

      by_key =
        rows
        |> Enum.reject(&is_nil(&1.item_id))
        |> Map.new(&{Resolver.name_key(&1.name), &1.item_id})

      attrs_list
      |> Enum.flat_map(fn attrs ->
        attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
        from = by_key[Resolver.name_key(to_string(attrs["name"] || ""))]
        links = if is_list(attrs["links"]), do: attrs["links"], else: []
        for link <- links, is_map(link), from, do: {from, link}
      end)
      |> Enum.reduce(%{made: 0, unknown: []}, fn {from, link}, acc ->
        link = Map.new(link, fn {k, v} -> {to_string(k), v} end)
        relation = to_string(link["relation"] || "") |> String.trim() |> String.downcase()
        target = to_string(link["target"] || "") |> String.trim()

        cond do
          relation not in @poet_relations or target == "" ->
            acc

          true ->
            case by_key[Resolver.name_key(target)] || known_item_id(target, entry.place_name) do
              nil ->
                %{acc | unknown: Enum.uniq(acc.unknown ++ [target])}

              ^from ->
                acc

              to ->
                case Spaces.link(from, to, relation, source: "poet", journal_entry_id: entry.id) do
                  {:ok, _} ->
                    if relation == "at", do: borrow_pin(from, to)
                    %{acc | made: acc.made + 1}

                  _ ->
                    acc
                end
            end
        end
      end)
    end)
  end

  # Something the app already knows by that name: in the same city first,
  # else anywhere when there is exactly one. Never a city, region or country.
  defp known_item_id(name, city) do
    key = Resolver.name_key(name)
    city_key = Resolver.city_key(city)

    base =
      Item
      |> where([i], i.status == "active" and i.norm_name == ^key)
      |> where([i], i.subkind not in @admin or is_nil(i.subkind))

    same_city =
      if city_key == "",
        do: nil,
        else:
          base
          |> where([i], fragment("lower(trim(coalesce(?, '')))", i.city) == ^city_key)
          |> select([i], i.id)
          |> limit(1)
          |> Repo.one()

    same_city ||
      case base |> select([i], i.id) |> limit(2) |> Repo.all() do
        [only] -> only
        _ -> nil
      end
  end

  # A dish at a restaurant, an exhibition at a museum: the thing sits where
  # its host does.
  defp borrow_pin(from_id, to_id) do
    with %Item{lat: nil} = from <- Repo.get(Item, from_id),
         %Item{lat: lat, lng: lng} when is_number(lat) <- Repo.get(Item, to_id) do
      from |> Item.changeset(%{lat: lat, lng: lng, geocode_status: "ok"}) |> Repo.update!()
    end

    :ok
  end

  ## Stays

  @doc """
  A path point is a stay in a city: resolves (or creates) the city item and
  points the path point at it. The city becomes the parent of the places
  found during the stay.
  """
  def stay_for(%PathPoint{} = point) do
    safely(point, fn ->
      case String.trim(point.place_name || "") do
        "" ->
          point

        name ->
          probe = %{
            kind: "place",
            subkind: "city",
            name: name,
            norm_name: Resolver.name_key(name),
            city: nil,
            lat: point.lat,
            lng: point.lng,
            source_url: nil,
            topic: nil,
            second_topic: nil,
            topics_classified_at: nil,
            time_start: nil,
            time_end: nil,
            parent_id: nil,
            country_code: nil
          }

          item = resolve_or_create(probe, point.poet_id)
          item = refresh(item, probe)
          # A city sits in a region and a country (Spaces.Hierarchy).
          Hierarchy.attach(item, name, point.country_code)
          point |> Ecto.Changeset.change(item_id: item.id) |> Repo.update!()
      end
    end)
  end

  defp stay_item_id(nil), do: nil

  defp stay_item_id(path_point_id) do
    case Repo.get(PathPoint, path_point_id) do
      %PathPoint{item_id: id} -> id
      nil -> nil
    end
  end

  # The country of the stay a place was found during, through the city item.
  defp stay_country(path_point_id) do
    case stay_item_id(path_point_id) do
      nil -> nil
      id -> Hierarchy.country_code_of(Repo.get(Item, id))
    end
  end

  # The city item for a free-text city name, if one exists; never created
  # here, because only a stay makes a city.
  defp city_item_id(city) do
    case Resolver.name_key(city) do
      "" ->
        nil

      key ->
        Item
        |> where([i], i.subkind == "city" and i.status == "active" and i.norm_name == ^key)
        |> select([i], i.id)
        |> limit(1)
        |> Repo.one()
    end
  end

  ## Resolution

  defp resolve_or_create(probe, poet_id) do
    case Resolver.decide(probe, candidates(probe)) do
      {:match, item} ->
        item

      {:series, earlier} ->
        {:ok, item} =
          Spaces.create_item(%{
            kind: probe.kind,
            subkind: probe.subkind,
            name: probe.name,
            city: probe.city,
            first_poet_id: poet_id
          })

        {:ok, _} = Spaces.link(item.id, earlier.id, "series_of")
        item

      {:new, reviews} ->
        {:ok, item} =
          Spaces.create_item(%{
            kind: probe.kind,
            subkind: probe.subkind,
            name: probe.name,
            city: probe.city,
            first_poet_id: poet_id
          })

        Enum.each(reviews, fn candidate ->
          %ItemReview{}
          |> ItemReview.changeset(%{
            item_id: item.id,
            candidate_id: candidate.id,
            reason: "similar name in #{probe.city || "the same place"}"
          })
          |> Repo.insert!()
        end)

        item
    end
  end

  # Same kind, active, and one of: same normalised name; same source URL;
  # same city; a pin inside a box around the probe's. The resolver measures
  # from there.
  defp candidates(probe) do
    key = probe.norm_name
    city = Resolver.city_key(probe.city)
    box = if probe.subkind == "city", do: @city_box_deg, else: @box_deg

    same_name = dynamic([i], i.norm_name == ^key)
    same_url = dynamic_url(Resolver.url_key(Map.get(probe, :source_url)))
    same_city = dynamic_city(city)
    in_box = dynamic_box(probe, box)

    Item
    |> where([i], i.kind == ^probe.kind and i.status == "active")
    |> where(^dynamic([i], ^same_name or ^same_url or ^same_city or ^in_box))
    |> maybe_subkind(probe.subkind)
    |> limit(200)
    |> Repo.all()
  end

  # A stay only ever matches another stay: a city is not a cafe of the same
  # name, and a country or region (Spaces.Hierarchy) is neither. Everything
  # else matches across subkinds (a "museum" and an "attraction" can be
  # one building).
  defp maybe_subkind(query, "city"), do: where(query, [i], i.subkind == "city")

  defp maybe_subkind(query, _),
    do: where(query, [i], i.subkind not in @admin or is_nil(i.subkind))

  defp dynamic_url(nil), do: dynamic([i], false)
  defp dynamic_url(key), do: dynamic([i], i.url_key == ^key)

  defp dynamic_city(""), do: dynamic([i], false)

  defp dynamic_city(city),
    do: dynamic([i], fragment("lower(trim(coalesce(?, '')))", i.city) == ^city)

  defp dynamic_box(%{lat: lat, lng: lng}, box) when is_number(lat) and is_number(lng) do
    dynamic(
      [i],
      i.lat >= ^(lat - box) and i.lat <= ^(lat + box) and i.lng >= ^(lng - box) and
        i.lng <= ^(lng + box)
    )
  end

  defp dynamic_box(_, _), do: dynamic([i], false)

  # What a visit teaches the item: a pin, a subject, a source, a parent, an
  # event's dates. Only ever fills what is empty; the first visit to say it
  # wins, and an admin fixes the rest.
  defp refresh(%Item{} = item, probe) do
    no_pin? = is_nil(item.lat)
    no_topic? = is_nil(item.topic)

    changes =
      [
        {:lat, probe.lat, no_pin?},
        {:lng, probe.lng, no_pin?},
        {:geocode_status, if(probe.lat, do: "ok"), no_pin?},
        {:topic, probe.topic, no_topic?},
        {:second_topic, probe.second_topic, no_topic?},
        {:topics_classified_at, probe.topics_classified_at, no_topic?},
        {:source_url, probe.source_url, is_nil(item.source_url)},
        {:parent_id, probe.parent_id, is_nil(item.parent_id)},
        {:city, probe.city, is_nil(item.city)},
        {:country_code, Map.get(probe, :country_code), is_nil(item.country_code)},
        {:time_start, probe.time_start, is_nil(item.time_start)},
        {:time_end, probe.time_end, is_nil(item.time_end)},
        {:era, Map.get(probe, :era), is_nil(item.era)}
      ]
      |> Enum.filter(fn {_field, value, empty?} -> empty? and not is_nil(value) end)
      |> Map.new(fn {field, value, _} -> {field, value} end)

    if map_size(changes) == 0,
      do: item,
      else: item |> Item.changeset(changes) |> Repo.update!()
  end

  defp safely(fallback, fun) do
    fun.()
  rescue
    e ->
      Logger.warning("Spaces.Ingest: #{Exception.message(e)}")
      fallback
  end
end
