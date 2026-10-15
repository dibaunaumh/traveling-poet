defmodule TravelingPoet.Spaces do
  @moduledoc """
  The Spaces model (kb-002, dec-001): shared `Item`s placed in a few
  `ReferenceSystem`s (geo, subject, time), related by `Link`s, with each
  poet's own rows (places, finds, stay areas, path points) pointing at the
  item they are a visit of.

  Phase 0 keeps those per-poet tables as the visits and adds the item on
  top: `Spaces.Ingest` resolves every row to an item as it is written, and
  `Spaces.Backfill` does the same for everything written before. This
  module is the read side and the small write helpers.

  Visibility: an item has no public face of its own in phase 0. Discover
  shows a merged place when a PUBLIC poet's published row points at it, so
  an item only private poets visited never surfaces (dec-001).
  """

  import Ecto.Query

  alias TravelingPoet.Repo
  alias TravelingPoet.Guide.{Place, StayArea}
  alias TravelingPoet.Journal.Entry
  alias TravelingPoet.Poets.{PathPoint, Poet}
  alias TravelingPoet.Spaces.{Item, ItemReview, Link, ReferenceSystem}
  alias TravelingPoet.Topics.Find

  def get_item(id), do: Repo.get(Item, id)

  @doc "The item behind a slug, following a merge to the item that absorbed it."
  def get_item_by_slug(slug) when is_binary(slug) do
    case Repo.get_by(Item, slug: slug) do
      %Item{status: "merged", merged_into_id: id} when not is_nil(id) -> get_item(id)
      item -> item
    end
  end

  def list_reference_systems, do: ReferenceSystem |> order_by(asc: :id) |> Repo.all()

  @doc "A slug no item has yet: the base, then base-2, base-3, ..."
  def unique_slug(base) do
    taken =
      Item
      |> where([i], i.slug == ^base or like(i.slug, ^"#{base}-%"))
      |> select([i], i.slug)
      |> Repo.all()
      |> MapSet.new()

    if MapSet.member?(taken, base) do
      Stream.iterate(2, &(&1 + 1))
      |> Stream.map(&"#{base}-#{&1}")
      |> Enum.find(&(not MapSet.member?(taken, &1)))
    else
      base
    end
  end

  @doc "Creates an item; the slug is derived from the name and made unique."
  def create_item(attrs) do
    name = attrs[:name] || attrs["name"] || ""
    slug = unique_slug(Item.base_slug(name))

    %Item{}
    |> Item.changeset(Map.put(Map.new(attrs), :slug, slug))
    |> Repo.insert()
  end

  @doc "Relates two items. Idempotent: the same link twice is one row."
  def link(from_id, to_id, relation, opts \\ []) do
    %Link{}
    |> Link.changeset(%{
      from_item_id: from_id,
      to_item_id: to_id,
      relation: relation,
      source: Keyword.get(opts, :source, "app"),
      journal_entry_id: Keyword.get(opts, :journal_entry_id)
    })
    |> Repo.insert(on_conflict: :nothing)
  end

  def links_from(item_id), do: Link |> where(from_item_id: ^item_id) |> Repo.all()

  @doc "The open resolution reviews, oldest first."
  def open_reviews do
    ItemReview
    |> where(status: "open")
    |> order_by(asc: :id)
    |> preload([:item, :candidate])
    |> Repo.all()
  end

  @doc """
  The public poets whose published rows point at this item, each once:
  who found it. `except` leaves one poet out (the one whose page you are on).
  """
  def found_by(item_id, opts \\ []) do
    except = Keyword.get(opts, :except)

    [place_poets(item_id), find_poets(item_id), area_poets(item_id)]
    |> Enum.concat()
    |> Enum.uniq_by(& &1.id)
    |> Enum.reject(&(&1.id == except))
  end

  defp place_poets(item_id) do
    Place
    |> join(:inner, [p], e in Entry, on: e.id == p.journal_entry_id)
    |> join(:inner, [p, _e], po in Poet, on: po.id == p.poet_id)
    |> where([p, e, po], p.item_id == ^item_id and e.status == "published")
    |> where([_p, _e, po], po.is_public and po.status == "active")
    |> select([_p, _e, po], po)
    |> distinct(true)
    |> Repo.all()
  end

  defp find_poets(item_id) do
    Find
    |> join(:inner, [f], e in Entry, on: e.id == f.journal_entry_id)
    |> join(:inner, [f, _e], po in Poet, on: po.id == f.poet_id)
    |> where([f, e, po], f.item_id == ^item_id and e.status == "published")
    |> where([_f, _e, po], po.is_public and po.status == "active")
    |> select([_f, _e, po], po)
    |> distinct(true)
    |> Repo.all()
  end

  defp area_poets(item_id) do
    StayArea
    |> join(:inner, [a], e in Entry, on: e.id == a.journal_entry_id)
    |> join(:inner, [a, _e], po in Poet, on: po.id == a.poet_id)
    |> where([a, e, po], a.item_id == ^item_id and e.status == "published")
    |> where([_a, _e, po], po.is_public and po.status == "active")
    |> select([_a, _e, po], po)
    |> distinct(true)
    |> Repo.all()
  end

  @doc """
  The time axis, for events: the active event items whose dates cover `on`,
  or start within `days` after it, soonest first. An event without dates
  is never "now".
  """
  def events_around(on \\ Date.utc_today(), days \\ 30) do
    horizon = Date.add(on, days)

    Item
    |> where([i], i.kind == "event" and i.status == "active" and not is_nil(i.time_start))
    |> where([i], i.time_start <= ^horizon)
    |> where([i], i.time_start >= ^on or (not is_nil(i.time_end) and i.time_end >= ^on))
    |> order_by([i], asc: i.time_start)
    |> Repo.all()
  end

  @doc "The earlier editions of an event, newest first (the series_of chain)."
  def earlier_editions(%Item{id: id}) do
    Link
    |> where([l], l.from_item_id == ^id and l.relation == "series_of")
    |> join(:inner, [l], i in Item, on: i.id == l.to_item_id)
    |> select([_l, i], i)
    |> Repo.all()
    |> Enum.sort_by(& &1.time_start, {:desc, Date})
  end

  @doc "The items directly under an item in the admin hierarchy (a country's regions, a region's cities)."
  def children(item_id, subkind) do
    Item
    |> where([i], i.parent_id == ^item_id and i.subkind == ^subkind and i.status == "active")
    |> order_by([i], asc: i.name)
    |> Repo.all()
  end

  @doc "The stays (path points) that are visits of this city item, newest first."
  def stays_at(item_id) do
    PathPoint |> where(item_id: ^item_id) |> order_by(desc: :arrived_at) |> Repo.all()
  end

  @doc """
  How many distinct poets' rows point at each item: `%{item_id => n}` over
  places, finds and stay areas. The backfill report's "shared" count.
  """
  def poets_per_item do
    [
      Place |> where([p], not is_nil(p.item_id)) |> select([p], {p.item_id, p.poet_id}),
      Find |> where([f], not is_nil(f.item_id)) |> select([f], {f.item_id, f.poet_id}),
      StayArea |> where([a], not is_nil(a.item_id)) |> select([a], {a.item_id, a.poet_id})
    ]
    |> Enum.flat_map(&Repo.all/1)
    |> Enum.uniq()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {item_id, poets} -> {item_id, length(poets)} end)
  end
end
