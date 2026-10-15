defmodule TravelingPoet.Narration.Backfill do
  @moduledoc """
  Narrates pages published before the feature existed. Runs in prod over
  `rpc`; a DRY RUN by default, which only counts and prices the work:

      bin/traveling_poet rpc 'TravelingPoet.Narration.Backfill.run()'
      bin/traveling_poet rpc 'TravelingPoet.Narration.Backfill.run(commit: true,limit: 20)'

  Options: `:commit` (default false), `:limit` (newest first, default 50),
  `:poet_id`, `:price_per_char` (USD, for the estimate; default from the
  2026-10-15 eval of Microsoft MAI-Voice-2.1-Flash, 0.000015).

  Each page goes through `Narration.generate/1`, so the reader's own switch
  and the daily cap apply; a backfill never narrates a page twice.
  """

  import Ecto.Query
  alias TravelingPoet.{Narration, Repo}
  alias TravelingPoet.Journal.Entry
  alias TravelingPoet.Narration.Script

  def run(opts \\ []) do
    commit? = Keyword.get(opts, :commit, false)
    limit = Keyword.get(opts, :limit, 50)
    price = Keyword.get(opts, :price_per_char, 0.000015)

    entries =
      Entry
      |> where([e], e.status == "published")
      |> maybe_poet(Keyword.get(opts, :poet_id))
      |> order_by(desc: :entry_date, desc: :id)
      |> preload(:sections)
      |> Repo.all()

    done = Narration.narration_by_entry(Enum.map(entries, & &1.id))

    todo =
      entries
      |> Enum.reject(&Map.has_key?(done, &1.id))
      |> Enum.map(&{&1, Script.for_entry(&1)})
      |> Enum.reject(fn {_e, text} -> is_nil(text) end)
      |> Enum.take(limit)

    chars = todo |> Enum.map(fn {_e, text} -> String.length(text) end) |> Enum.sum()

    results =
      if commit? do
        Enum.map(todo, fn {entry, _text} ->
          r = Narration.generate(entry)
          Process.sleep(500)
          {entry.id, summarize(r)}
        end)
      else
        []
      end

    %{
      committed: commit?,
      published: length(entries),
      already_narrated: map_size(done),
      to_narrate: length(todo),
      chars: chars,
      estimated_usd: Float.round(chars * price, 4),
      results: results
    }
  end

  defp maybe_poet(query, nil), do: query
  defp maybe_poet(query, poet_id), do: where(query, [e], e.poet_id == ^poet_id)

  defp summarize({:ok, media}), do: {:ok, media.duration_seconds}
  defp summarize({:skip, why}), do: {:skip, why}
  defp summarize({:error, why}), do: {:error, why}
end
