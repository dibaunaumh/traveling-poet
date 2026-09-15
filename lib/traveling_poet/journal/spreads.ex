defmodule TravelingPoet.Journal.Spreads do
  @moduledoc """
  How an entry lies across two facing pages. Pure, so the owner's journal, a
  public journal and the home page all open the same notebook.

  "Today" puts the words on the left (the description, then the practical
  notes in the order the poet wrote them) and the drawing and poem on the
  right, so the picture is in view without scrolling past the prose. That is
  the whole point: an entry used to read as a wall of text with the drawing
  below the fold.

  Items are `{:section, section}` or `{:media, media}`, the latter a drawing
  linked to the entry that no section claimed (the app draws it anyway rather
  than lose a paid-for illustration to a fumbled `media_id`).

  "Places" brings the day's trip guide into the notebook: the map on the
  left, the stops the poet would send you to on the right. Readers were not
  opening the Guide; now it is one tab away from the entry that mentions
  them. The map page is rendered by the caller (it owns the Leaflet hook), so
  the left side is the single item `{:map, nil}`; stops are `{:place, place}`.

  An excursion entry (a day off the road, into a topic) has no places to
  pin; its second spread is "Finds": the excursion itself on the left as
  `{:excursion, excursion}`, what it brought back on the right as
  `{:find, find}`. The fourth argument then carries finds instead of places.
  """

  @type item :: {:section, map} | {:media, map}
  @type spread :: %{key: String.t(), label: String.t(), left: [item], right: [item]}

  @right_kinds ~w(illustration poem)

  @doc """
  The spreads for an entry, in reading order: Today, then Places (or Finds
  for an excursion). An entry with no places still gets the Places tab (an
  empty page that says so beats a tab that comes and goes between days).
  """
  @spec pack(map | nil, %{optional(integer) => map}, [map], [map], Date.t()) :: [spread]
  def pack(entry, media_by_id, extra_media, side_items \\ [], today \\ Date.utc_today())

  def pack(nil, _media_by_id, _extra_media, _side_items, _today), do: []

  def pack(entry, media_by_id, extra_media, side_items, today) do
    {right, left} = Enum.split_with(entry.sections, &(&1.kind in @right_kinds))

    # An illustration section whose drawing is missing would render nothing
    # but still claim a slot; it goes, as it does on the single page.
    drawings =
      Enum.filter(right, &(&1.kind == "illustration" and Map.has_key?(media_by_id, &1.media_id)))

    poems = Enum.filter(right, &(&1.kind == "poem"))

    [
      %{
        key: "today",
        label: entry_label(entry, today),
        left: Enum.map(left, &{:section, &1}),
        right:
          Enum.map(drawings, &{:section, &1}) ++
            Enum.map(extra_media, &{:media, &1}) ++
            Enum.map(poems, &{:section, &1})
      },
      side_spread(entry, side_items)
    ]
  end

  defp side_spread(entry, items) do
    case excursion_of(entry) do
      nil ->
        %{
          key: "places",
          label: "Places",
          left: [{:map, nil}],
          right: Enum.map(items, &{:place, &1})
        }

      excursion ->
        %{
          key: "finds",
          label: "Finds",
          left: [{:excursion, excursion}],
          right: Enum.map(items, &{:find, &1})
        }
    end
  end

  # Pure: reads only what the caller loaded. An unloaded association counts
  # as no excursion; callers that want the Finds spread preload it.
  defp excursion_of(entry) do
    case Map.get(entry, :excursion) do
      %{__struct__: Ecto.Association.NotLoaded} -> nil
      other -> other
    end
  end

  # The tab names the day, and only today's entry is "Today": paging back
  # to an earlier entry, the tab reads its date, not a promise it cannot keep.
  defp entry_label(%{entry_date: %Date{} = date}, today) do
    if Date.compare(date, today) == :eq, do: "Today", else: Calendar.strftime(date, "%b %-d")
  end

  defp entry_label(_entry, _today), do: "Entry"

  @doc """
  The spread a reader asked for by key, or the first one when the key is
  unknown (a stale link, a typo in the URL). Nil only when there is nothing
  to show.
  """
  @spec pick([spread], String.t() | nil) :: spread | nil
  def pick([], _requested), do: nil

  def pick(spreads, requested) do
    Enum.find(spreads, hd(spreads), &(&1.key == requested))
  end
end
