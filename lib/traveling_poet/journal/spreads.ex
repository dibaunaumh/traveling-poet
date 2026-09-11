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
  """

  @type item :: {:section, map} | {:media, map}
  @type spread :: %{key: String.t(), label: String.t(), left: [item], right: [item]}

  @right_kinds ~w(illustration poem)

  @doc """
  The spreads for an entry, in reading order: Today, then Places. An entry
  with no places still gets the Places tab (an empty page that says so beats
  a tab that comes and goes between days).
  """
  @spec pack(map | nil, %{optional(integer) => map}, [map], [map]) :: [spread]
  def pack(entry, media_by_id, extra_media, places \\ [])

  def pack(nil, _media_by_id, _extra_media, _places), do: []

  def pack(entry, media_by_id, extra_media, places) do
    {right, left} = Enum.split_with(entry.sections, &(&1.kind in @right_kinds))

    # An illustration section whose drawing is missing would render nothing
    # but still claim a slot; it goes, as it does on the single page.
    drawings =
      Enum.filter(right, &(&1.kind == "illustration" and Map.has_key?(media_by_id, &1.media_id)))

    poems = Enum.filter(right, &(&1.kind == "poem"))

    [
      %{
        key: "today",
        label: "Today",
        left: Enum.map(left, &{:section, &1}),
        right:
          Enum.map(drawings, &{:section, &1}) ++
            Enum.map(extra_media, &{:media, &1}) ++
            Enum.map(poems, &{:section, &1})
      },
      %{
        key: "places",
        label: "Places",
        left: [{:map, nil}],
        right: Enum.map(places, &{:place, &1})
      }
    ]
  end

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
