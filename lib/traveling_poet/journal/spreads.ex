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
  """

  @type item :: {:section, map} | {:media, map}
  @type spread :: %{key: String.t(), label: String.t(), left: [item], right: [item]}

  @right_kinds ~w(illustration poem)

  @doc "The spreads for an entry, in reading order. An entry always has at least Today."
  @spec pack(map | nil, %{optional(integer) => map}, [map]) :: [spread]
  def pack(nil, _media_by_id, _extra_media), do: []

  def pack(entry, media_by_id, extra_media) do
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
