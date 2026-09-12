defmodule TravelingPoet.Journal.Spots do
  @moduledoc """
  Spot drawings a poet made but never pasted into the text.

  The wiring step (paste the returned markdown into the body) is the one the
  models fumble, as they did with the illustration section's media_id. A
  paid-for drawing must not vanish over that: at render time every spot
  linked to the entry that no body embeds is woven into the description,
  spread through the text (before the 2nd paragraph, then the 4th, and so
  on) so the page reads as illustrated rather than headed by a picture.
  Pure: the stored body is untouched, only what the page shows changes.
  """

  alias TravelingPoet.Journal

  @hosts ~w(description art_culture products kindness)

  @doc "The sections with every unclaimed spot drawing placed into the prose."
  def embed_unclaimed(sections, []), do: sections

  def embed_unclaimed(sections, spots) do
    embedded = referenced_ids(sections)

    case Enum.reject(spots, &(&1.id in embedded)) do
      [] -> sections
      unclaimed -> place(sections, unclaimed)
    end
  end

  defp referenced_ids(sections) do
    sections
    |> Enum.flat_map(fn s ->
      Regex.scan(~r{\]\(/media/(\d+)\)}, s.body || "")
      |> Enum.map(fn [_, id] -> String.to_integer(id) end)
    end)
    |> MapSet.new()
  end

  # The description hosts them; failing that the first prose section.
  defp place(sections, unclaimed) do
    host =
      Enum.find_index(sections, &(&1.kind == "description")) ||
        Enum.find_index(sections, &(&1.kind in @hosts))

    case host do
      nil -> sections
      idx -> List.update_at(sections, idx, &%{&1 | body: weave(&1.body, unclaimed)})
    end
  end

  # Before the 2nd, 4th, 6th paragraph: never the first, which sits beside
  # the heading; anything the text is too short to host goes at the end.
  defp weave(body, spots) do
    paragraphs = String.split(body || "", ~r/\n{2,}/, trim: true)

    targets =
      spots
      |> Enum.with_index()
      |> Map.new(fn {spot, i} -> {1 + 2 * i, Journal.spot_markdown(spot)} end)

    {woven, leftover} =
      paragraphs
      |> Enum.with_index()
      |> Enum.reduce({[], targets}, fn {paragraph, i}, {acc, targets} ->
        case Map.pop(targets, i) do
          {nil, targets} -> {[paragraph | acc], targets}
          {line, targets} -> {[paragraph, line | acc], targets}
        end
      end)

    tail = leftover |> Enum.sort() |> Enum.map(&elem(&1, 1))
    Enum.join(Enum.reverse(woven) ++ tail, "\n\n")
  end
end
