defmodule TravelingPoet.Journal.EntryBundle do
  @moduledoc """
  Everything a page needs to render one journal entry, loaded once.

  The owner's journal, the public journal and the home page each grew their
  own copy of the same dozen lines: the media the sections point at, the
  drawings no section claimed, the spot drawings woven into the prose, the
  day's places or finds and their drawings, the stay the day belongs to, and
  the spreads laid across the notebook. Three copies drifted in small ways
  and none of them could load a whole journey. This is the one loader; the
  book asks for every entry at once through `load_many/2`, which batches the
  lookups so a hundred days cost a handful of queries.

  Pure layout stays where it was: `Journal.Spreads` and `Journal.Spots` are
  called from here, not reimplemented.
  """

  alias TravelingPoet.{Guide, Journal, Poets, Topics}
  alias TravelingPoet.Journal.{Spots, Spreads}

  defstruct entry: nil,
            media: %{},
            extra_media: [],
            spot_media: %{},
            places: [],
            finds: [],
            place_media: %{},
            find_media: %{},
            stay_id: nil,
            spreads: []

  @type t :: %__MODULE__{}

  @doc """
  The bundle for one entry; an empty bundle for nil, so callers can read its
  fields without a nil check. `stays:` hands in the poet's path points when
  the caller already has them.
  """
  @spec load(map | nil, keyword) :: t
  def load(entry, opts \\ [])
  def load(nil, _opts), do: %__MODULE__{}
  def load(entry, opts), do: entry |> List.wrap() |> load_many(opts) |> hd()

  @doc """
  Bundles for many entries of one poet, in the order given. Sections and the
  excursion are preloaded if they are not already; every other lookup is one
  query for the whole list.
  """
  @spec load_many([map], keyword) :: [t]
  def load_many(entries, opts \\ [])
  def load_many([], _opts), do: []

  def load_many(entries, opts) do
    entries = ensure_preloaded(entries)
    entry_ids = Enum.map(entries, & &1.id)
    stays = Keyword.get_lazy(opts, :stays, fn -> Poets.list_path_points(hd(entries).poet_id) end)

    spots_by_entry = Journal.spot_media_by_entry(entry_ids)
    extra_by_entry = Journal.unattached_illustrations_by_entry(entries)
    places_by_entry = Guide.list_places_for_entries(entry_ids)
    finds_by_entry = Topics.list_finds_for_entries(entry_ids)

    media_ids =
      Enum.flat_map(entries, fn e -> Enum.map(e.sections, & &1.media_id) end) ++
        Enum.flat_map(Map.values(places_by_entry), fn ps -> Enum.map(ps, & &1.media_id) end) ++
        Enum.flat_map(Map.values(finds_by_entry), fn fs -> Enum.map(fs, & &1.media_id) end)

    all_media = Journal.media_by_ids(media_ids)

    Enum.map(entries, fn entry ->
      spots = Map.get(spots_by_entry, entry.id, [])
      entry = %{entry | sections: Spots.embed_unclaimed(entry.sections, spots)}

      media = pick(all_media, Enum.map(entry.sections, & &1.media_id))
      extra = Map.get(extra_by_entry, entry.id, [])

      # A day at the place has places; an excursion has finds; never both.
      {places, finds} =
        if Topics.excursion_of(entry),
          do: {[], Map.get(finds_by_entry, entry.id, [])},
          else: {Map.get(places_by_entry, entry.id, []), []}

      %__MODULE__{
        entry: entry,
        media: media,
        extra_media: extra,
        spot_media: Map.new(spots, &{&1.id, &1}),
        places: places,
        finds: finds,
        place_media: pick(all_media, Enum.map(places, & &1.media_id)),
        find_media: pick(all_media, Enum.map(finds, & &1.media_id)),
        stay_id: Guide.path_point_for(entry, stays),
        spreads: Spreads.pack(entry, media, extra, places ++ finds)
      }
    end)
  end

  defp pick(all_media, ids) do
    ids
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(fn id ->
      case Map.fetch(all_media, id) do
        {:ok, m} -> [{id, m}]
        :error -> []
      end
    end)
    |> Map.new()
  end

  defp ensure_preloaded(entries) do
    if Enum.all?(
         entries,
         &(Ecto.assoc_loaded?(&1.sections) and Ecto.assoc_loaded?(&1.excursion))
       ),
       do: entries,
       else: Journal.preload_entries(entries)
  end
end
