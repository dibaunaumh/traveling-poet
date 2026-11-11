defmodule TravelingPoet.Journal.PageFacts do
  @moduledoc """
  What a journal page holds and what it lacks, counted in one place: the
  publish reply tells the poet what is missing (`JournalApiController`), and
  the Alice-in-Context tap reports the same facts with the page
  (`TravelingPoet.AiC.journal_published/1`), so the two can not disagree.

  A page has at most six parts, in reading order: `story` (the description),
  `drawing`, `poem`, `notes` (art and culture, products, kindness, or an
  excursion's highlights), `places` (an excursion has `finds` instead) and
  `stay`. Prose is counted in words, the rest in items. A part with nothing
  in it is left out.
  """

  alias TravelingPoet.{Guide, Journal, Topics}

  @note_kinds ~w(art_culture products kindness highlights)

  @doc "`%{parts: [%{id, words | count}], missing: [id]}` for an entry."
  def of(entry) do
    sections = Journal.preload_entry(entry).sections
    excursion? = Topics.excursion_of(entry) != nil

    drawings =
      Enum.count(sections, &(&1.kind == "illustration" and &1.media_id != nil)) +
        length(Journal.unattached_illustrations(entry, sections))

    places = length(Guide.list_places_for_entry(entry.id))
    finds = length(Topics.list_finds_for_entry(entry.id))
    stay = [entry.id] |> Guide.Stay.list_for_entries() |> Map.get(entry.id, []) |> length()

    parts =
      [
        words("story", sections, ["description"]),
        count("drawing", drawings),
        words("poem", sections, ["poem"]),
        words("notes", sections, @note_kinds),
        count("places", places),
        count("finds", finds),
        count("stay", stay)
      ]
      |> Enum.reject(&is_nil/1)

    missing =
      [
        # A day at a place with nothing in the trip guide leaves the reader an
        # empty Places tab; an excursion has finds instead.
        if(not excursion? and places == 0, do: "places"),
        # A drawing generated but never put on a section still shows.
        if(drawings == 0, do: "drawing")
      ]
      |> Enum.reject(&is_nil/1)

    %{parts: parts, missing: missing}
  end

  @doc "The part of the page a section kind (or a spread) belongs to, or nil."
  def part_of("description"), do: "story"
  def part_of("illustration"), do: "drawing"
  def part_of("poem"), do: "poem"
  def part_of(kind) when kind in @note_kinds, do: "notes"
  def part_of(part) when part in ~w(places finds stay), do: part
  def part_of(_), do: nil

  defp count(_id, 0), do: nil
  defp count(id, n), do: %{id: id, count: n}

  defp words(id, sections, kinds) do
    n =
      sections
      |> Enum.filter(&(&1.kind in kinds))
      |> Enum.map(&word_count(&1.body))
      |> Enum.sum()

    if n > 0, do: %{id: id, words: n}
  end

  defp word_count(nil), do: 0
  defp word_count(body), do: body |> String.split(~r/\s+/u, trim: true) |> length()
end
