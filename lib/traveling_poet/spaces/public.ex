defmodule TravelingPoet.Spaces.Public do
  @moduledoc """
  The public face of the Spaces items (kb-002 phase 3): what anyone may
  read about an item, and the one rule that decides whether an item has a
  public face at all. An item is public when at least one PUBLIC poet's
  PUBLISHED row (a place, a find, a stay area) points at it; private
  visits never create or reveal anything (dec-001). Every export here
  reads through that rule, so a crafted slug or a filter gets nothing a
  private poet found.
  """

  import Ecto.Query

  alias TravelingPoet.{Repo, Spaces}
  alias TravelingPoet.Guide.{Place, PlaceTopics, StayArea}
  alias TravelingPoet.Journal.Entry
  alias TravelingPoet.Poets.Poet
  alias TravelingPoet.Spaces.Item
  alias TravelingPoet.Topics.Find

  @admin ~w(city region country)

  @doc """
  The item behind a public slug: `{:ok, item}`, `{:moved, slug}` when the
  slug was merged into another item (the caller redirects), or `:none`
  when nothing public has that slug.
  """
  def lookup(slug) when is_binary(slug) do
    case Repo.get_by(Item, slug: slug) do
      nil ->
        :none

      %Item{status: "merged", merged_into_id: id} when is_integer(id) ->
        case Repo.get(Item, id) do
          %Item{status: "active"} = into -> if public?(into), do: {:moved, into.slug}, else: :none
          _ -> :none
        end

      %Item{status: "active"} = item ->
        if public?(item), do: {:ok, item}, else: :none

      _ ->
        :none
    end
  end

  def lookup(_), do: :none

  @doc "Whether a public poet has published a row of this item."
  def public?(%Item{id: id}) do
    Item |> where([i], i.id == ^id) |> public_only() |> Repo.exists?()
  end

  @doc "Narrows an Item query to the items with a public face."
  def public_only(query) do
    from(i in query,
      as: :item,
      where:
        exists(public_rows(Place)) or exists(public_rows(Find)) or exists(public_rows(StayArea))
    )
  end

  defp public_rows(schema) do
    from(r in schema,
      join: e in Entry,
      on: e.id == r.journal_entry_id,
      join: po in Poet,
      on: po.id == r.poet_id,
      where:
        r.item_id == parent_as(:item).id and e.status == "published" and po.is_public and
          po.status == "active",
      select: 1
    )
  end

  @doc """
  What the public poets wrote about an item, newest first: one note per
  published row, with the poet and the page it came from.
  """
  def notes(%Item{id: id}) do
    places =
      Place
      |> join(:inner, [p], e in Entry, on: e.id == p.journal_entry_id)
      |> join(:inner, [p, _e], po in Poet, on: po.id == p.poet_id)
      |> where([p, e, po], p.item_id == ^id and e.status == "published")
      |> where([_p, _e, po], po.is_public and po.status == "active")
      |> select([p, e, po], %{
        kind: :place,
        id: p.id,
        date: e.entry_date,
        blurb: p.blurb,
        rating: p.poet_rating,
        address: p.address,
        hours: p.hours,
        poet: %{name: po.name, slug: po.slug}
      })
      |> Repo.all()

    finds =
      Find
      |> join(:inner, [f], e in Entry, on: e.id == f.journal_entry_id)
      |> join(:inner, [f, _e], po in Poet, on: po.id == f.poet_id)
      |> where([f, e, po], f.item_id == ^id and e.status == "published")
      |> where([_f, _e, po], po.is_public and po.status == "active")
      |> select([f, e, po], %{
        kind: :find,
        id: f.id,
        date: e.entry_date,
        blurb: f.blurb,
        rating: f.poet_rating,
        address: nil,
        hours: nil,
        poet: %{name: po.name, slug: po.slug}
      })
      |> Repo.all()

    areas =
      StayArea
      |> join(:inner, [a], e in Entry, on: e.id == a.journal_entry_id)
      |> join(:inner, [a, _e], po in Poet, on: po.id == a.poet_id)
      |> where([a, e, po], a.item_id == ^id and e.status == "published")
      |> where([_a, _e, po], po.is_public and po.status == "active")
      |> select([a, e, po], %{
        kind: :area,
        id: a.id,
        date: e.entry_date,
        blurb: a.summary,
        rating: nil,
        address: nil,
        hours: nil,
        poet: %{name: po.name, slug: po.slug}
      })
      |> Repo.all()

    (places ++ finds ++ areas) |> Enum.sort_by(&{&1.date, &1.id}, {:desc, Date})
  end

  @doc """
  Everything a page or a JSON-LD document says about a public item:
  `%{item, notes, poets, topics, parent, related, editions}`. `related`
  and `editions` keep only items with a public face of their own.
  """
  def facts(%Item{} = item) do
    notes = notes(item)

    %{
      item: item,
      notes: notes,
      poets: notes |> Enum.map(& &1.poet) |> Enum.uniq_by(& &1.slug),
      topics:
        [item.topic, item.second_topic]
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&{&1, PlaceTopics.names(&1)})
        |> Enum.reject(fn {_path, names} -> is_nil(names) end),
      parent: item.parent_id && Repo.get(Item, item.parent_id),
      related: item.id |> Spaces.related() |> Enum.filter(&public?(&1.item)),
      editions: item |> Spaces.earlier_editions() |> Enum.filter(&public?/1)
    }
  end

  @doc """
  The mapped public items as GeoJSON features, in the order they were
  created. Filters: `kind`, `topic` (a path prefix on the subject tree),
  `country` (ISO code). Cities, regions and countries are left out: a
  feed of places, not of the map's own grid.
  """
  def geojson(filters \\ %{}) do
    found_by = public_poets_per_item()

    features =
      Item
      |> where([i], i.status == "active" and not is_nil(i.lat) and not is_nil(i.lng))
      |> where([i], i.subkind not in @admin or is_nil(i.subkind))
      |> filter_kind(filters["kind"])
      |> filter_topic(filters["topic"])
      |> filter_country(filters["country"])
      |> public_only()
      |> order_by([i], asc: i.id)
      |> Repo.all()
      |> Enum.map(&feature(&1, Map.get(found_by, &1.id, 0)))

    %{"type" => "FeatureCollection", "features" => features}
  end

  defp feature(%Item{} = i, found_by) do
    %{
      "type" => "Feature",
      "id" => i.slug,
      "geometry" => %{"type" => "Point", "coordinates" => [i.lng, i.lat]},
      "properties" =>
        %{
          "name" => i.name,
          "slug" => i.slug,
          "kind" => i.kind,
          "subkind" => i.subkind,
          "city" => i.city,
          "country" => i.country_code,
          "topic" => i.topic,
          "second_topic" => i.second_topic,
          "starts" => i.time_start && Date.to_iso8601(i.time_start),
          "ends" => i.time_end && Date.to_iso8601(i.time_end),
          "era" => i.era,
          "found_by" => found_by
        }
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()
    }
  end

  defp filter_kind(query, kind) when kind in [nil, ""], do: query
  defp filter_kind(query, kind), do: where(query, [i], i.kind == ^kind)

  defp filter_topic(query, topic) when topic in [nil, ""], do: query

  defp filter_topic(query, topic) do
    prefix = topic <> "/"

    where(
      query,
      [i],
      i.topic == ^topic or like(i.topic, ^(prefix <> "%")) or i.second_topic == ^topic or
        like(i.second_topic, ^(prefix <> "%"))
    )
  end

  defp filter_country(query, code) when code in [nil, ""], do: query
  defp filter_country(query, code), do: where(query, [i], i.country_code == ^String.upcase(code))

  # How many public poets published a row of each item, one query per table.
  defp public_poets_per_item do
    [Place, Find, StayArea]
    |> Enum.flat_map(fn schema ->
      schema
      |> join(:inner, [r], e in Entry, on: e.id == r.journal_entry_id)
      |> join(:inner, [r, _e], po in Poet, on: po.id == r.poet_id)
      |> where([r, e, po], not is_nil(r.item_id) and e.status == "published")
      |> where([_r, _e, po], po.is_public and po.status == "active")
      |> select([r], {r.item_id, r.poet_id})
      |> distinct(true)
      |> Repo.all()
    end)
    |> Enum.uniq()
    |> Enum.group_by(&elem(&1, 0))
    |> Map.new(fn {item_id, pairs} -> {item_id, length(pairs)} end)
  end
end
