defmodule TravelingPoet.Spaces.Backfill do
  @moduledoc """
  Resolves everything written before the Spaces model existed (kb-002,
  phase 0): every path point to a city item, every place, find and stay
  area to the item it is a visit of. The same `Spaces.Ingest` the live
  write path uses, so the backfill and a put can never disagree.

  A DRY RUN by default: it runs the whole thing inside a transaction and
  rolls it back, reporting what it would have written. `commit: true`
  keeps it. Rows that already point at an item are left alone unless
  `force: true`.

  In production (a release, no Mix):

      bin/traveling_poet rpc 'TravelingPoet.Spaces.Backfill.run(commit: true)'

  `mix tpoet.backfill_spaces` is the local formatter around this.
  """

  import Ecto.Query

  alias TravelingPoet.{Repo, Spaces}
  alias TravelingPoet.Guide.{Place, StayArea}
  alias TravelingPoet.Journal.Entry
  alias TravelingPoet.Poets.PathPoint
  alias TravelingPoet.Spaces.{Hierarchy, Ingest, Item, ItemReview, Link}
  alias TravelingPoet.Topics.Find

  @doc """
  Options: `:commit` (default false), `:poet_id`, `:force` (re-resolve rows
  that already have an item).

  Returns a report: `%{committed, linked: %{stays, places, finds, areas},
  hierarchy: %{cities_placed, countries, regions, coded}, series,
  items_created, by_kind, shared, reviews, samples}`.
  """
  def run(opts \\ []) do
    commit? = Keyword.get(opts, :commit, false)

    Repo.transaction(fn ->
      report = do_run(opts)
      if commit?, do: report, else: Repo.rollback({:dry_run, report})
    end)
    |> case do
      {:ok, report} -> Map.put(report, :committed, true)
      {:error, {:dry_run, report}} -> Map.put(report, :committed, false)
    end
  end

  defp do_run(opts) do
    items_before = Repo.aggregate(Item, :count)
    reviews_before = Repo.aggregate(ItemReview, :count)

    links_before = Repo.aggregate(Link, :count)
    stays = Enum.count(path_points(opts), &linked?(Ingest.stay_for(&1)))
    hierarchy = Hierarchy.backfill()

    places =
      opts
      |> rows(Place)
      |> Enum.group_by(& &1.journal_entry_id)
      |> Enum.reduce(0, fn {entry_id, places}, n ->
        case Repo.get(Entry, entry_id) do
          nil -> n
          entry -> n + Enum.count(Ingest.sync_places(entry, places), &linked?/1)
        end
      end)

    finds =
      opts
      |> rows(Find)
      |> Enum.group_by(& &1.journal_entry_id)
      |> Enum.reduce(0, fn {entry_id, finds}, n ->
        case Repo.get(Entry, entry_id) do
          nil -> n
          entry -> n + Enum.count(Ingest.sync_finds(entry, finds), &linked?/1)
        end
      end)

    areas =
      opts
      |> rows(StayArea)
      |> Enum.group_by(& &1.journal_entry_id)
      |> Enum.reduce(0, fn {entry_id, areas}, n ->
        case Repo.get(Entry, entry_id) do
          nil -> n
          entry -> n + Enum.count(Ingest.sync_areas(entry, areas), &linked?/1)
        end
      end)

    per_item = Spaces.poets_per_item()
    shared = per_item |> Enum.filter(fn {_id, n} -> n > 1 end) |> Map.new()
    # Places found before the cities were placed take their codes now.
    coded_late = Hierarchy.backfill().coded

    %{
      linked: %{stays: stays, places: places, finds: finds, areas: areas},
      hierarchy: %{hierarchy | coded: hierarchy.coded + coded_late},
      series:
        Repo.aggregate(from(l in Link, where: l.relation == "series_of"), :count) -
          links_before_series(links_before),
      items_created: Repo.aggregate(Item, :count) - items_before,
      by_kind: by_kind(),
      shared: map_size(shared),
      reviews: Repo.aggregate(ItemReview, :count) - reviews_before,
      samples: samples(shared)
    }
  end

  defp linked?(%{item_id: id}), do: not is_nil(id)
  defp linked?(_), do: false

  # Links are only ever series_of in phase 1, so the total before is the
  # series count before.
  defp links_before_series(n), do: n

  defp path_points(opts) do
    PathPoint
    |> maybe_poet(opts[:poet_id])
    |> maybe_unlinked(opts)
    |> order_by(asc: :poet_id, asc: :position)
    |> Repo.all()
  end

  defp rows(opts, schema) do
    schema
    |> maybe_poet(opts[:poet_id])
    |> maybe_unlinked(opts)
    |> order_by(asc: :id)
    |> Repo.all()
  end

  defp maybe_poet(query, nil), do: query
  defp maybe_poet(query, poet_id), do: where(query, [r], r.poet_id == ^poet_id)

  defp maybe_unlinked(query, opts) do
    if Keyword.get(opts, :force, false),
      do: query,
      else: where(query, [r], is_nil(r.item_id))
  end

  defp by_kind do
    Item
    |> where(status: "active")
    |> group_by([i], i.kind)
    |> select([i], {i.kind, count(i.id)})
    |> Repo.all()
    |> Map.new()
  end

  # The most-shared items, so the report shows what the merge actually did.
  defp samples(shared) do
    ids = shared |> Enum.sort_by(fn {_id, n} -> -n end) |> Enum.take(15) |> Enum.map(&elem(&1, 0))

    Item
    |> where([i], i.id in ^ids)
    |> Repo.all()
    |> Enum.map(&%{name: &1.name, city: &1.city, kind: &1.kind, poets: shared[&1.id]})
    |> Enum.sort_by(&(-&1.poets))
  end
end
