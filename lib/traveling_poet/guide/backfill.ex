defmodule TravelingPoet.Guide.Backfill do
  @moduledoc """
  Extracts trip-guide places from already-published entries.

  A plain module rather than logic living inside the Mix task, because the Mix
  task cannot run where this is actually needed: production is a release, and
  a release has no Mix. This is callable over `bin/traveling_poet rpc`, and
  `mix tpoet.backfill_places` is a thin formatter around it for local use.

  Pacing is left to `Geocoder.Limiter`, which already serializes every
  Nominatim call in the app to 1 req/s. A second delay knob here would just be
  a slower duplicate of a guarantee that already holds.
  """

  import Ecto.Query

  require Logger

  alias TravelingPoet.{Guide, Journal, Repo}
  alias TravelingPoet.Guide.{Extractor, Geocoding}
  alias TravelingPoet.Journal.Entry

  @default_limit 25
  # Matches the agent endpoint's cap. An entry that mentions twenty places is
  # a wall, not a guide, and the two write paths should not disagree about
  # what a day's list may look like.
  @max_places_per_entry 8

  @doc "The per-entry place cap, shared with the agent endpoint."
  def max_places_per_entry, do: @max_places_per_entry

  @doc """
  Options: `:poet_id`, `:limit` (default 25), `:commit` (default false —
  dry run), `:force` (re-extract entries that already have places),
  `:geocode` (default true).

  Returns `%{entries: [...], totals: %{...}}`. Dry runs still call the model,
  because the extraction is the part worth previewing; they simply write
  nothing.
  """
  def run(opts \\ []) do
    commit? = Keyword.get(opts, :commit, false)

    results =
      opts
      |> candidates()
      |> Enum.map(&process(&1, opts, commit?))

    %{entries: results, totals: totals(results, commit?)}
  end

  defp candidates(opts) do
    Entry
    |> where(status: "published")
    |> maybe_poet(opts[:poet_id])
    |> order_by(desc: :entry_date)
    |> limit(^Keyword.get(opts, :limit, @default_limit))
    |> Repo.all()
    |> Enum.map(&Journal.preload_entry/1)
  end

  defp maybe_poet(query, nil), do: query
  defp maybe_poet(query, poet_id), do: where(query, poet_id: ^poet_id)

  defp process(entry, opts, commit?) do
    base = %{poet_id: entry.poet_id, date: entry.entry_date, city: entry.place_name}

    if not Keyword.get(opts, :force, false) and Guide.list_places_for_entry(entry.id) != [] do
      Map.merge(base, %{status: :skipped_has_places, places: []})
    else
      extract(entry, base, opts, commit?)
    end
  end

  defp extract(entry, base, opts, commit?) do
    case Extractor.extract(entry, entry.sections) do
      {:ok, []} ->
        Map.merge(base, %{status: :nothing_named, places: []})

      {:ok, all} ->
        places = Enum.take(all, @max_places_per_entry)
        names = Enum.map(places, &{&1["name"], &1["category"], &1["address"]})
        if commit?, do: write(entry, places, opts)
        Map.merge(base, %{status: if(commit?, do: :written, else: :dry_run), places: names})

      {:error, reason} ->
        # A failed or malformed extraction skips the entry. It must never take
        # the rest of the run down with it.
        Logger.warning("Backfill: #{entry.entry_date} failed: #{inspect(reason)}")
        Map.merge(base, %{status: {:failed, reason}, places: []})
    end
  end

  defp write(entry, places, opts) do
    case Guide.replace_places(entry, places) do
      {:ok, saved} ->
        if Keyword.get(opts, :geocode, true) do
          Enum.each(saved, &Geocoding.resolve(&1, entry.place_name))
        end

      {:error, reason} ->
        Logger.warning("Backfill: write failed for #{entry.entry_date}: #{inspect(reason)}")
    end
  end

  defp totals(results, commit?) do
    %{
      entries: length(results),
      places: results |> Enum.map(&length(&1.places)) |> Enum.sum(),
      skipped: Enum.count(results, &(&1.status in [:skipped_has_places, :nothing_named])),
      failed: Enum.count(results, &match?({:failed, _}, &1.status)),
      committed: commit?
    }
  end
end
