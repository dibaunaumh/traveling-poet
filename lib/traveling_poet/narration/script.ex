defmodule TravelingPoet.Narration.Script do
  @moduledoc """
  What the narrator reads: the entry's prose in page order, as plain text.

  Pure. The Today spread puts the prose on the left page and the poem on
  the right, so the script reads the title, every prose section in its
  stored order, and the poems last, the way the eye crosses the spread.
  Section titles are read as their own short line. Markdown is flattened:
  images go, links keep their text, emphasis and heading marks go. Nothing
  here touches the stored body.
  """

  alias TravelingPoet.Journal.Spreads

  @doc "The narration text for an entry with its sections loaded, or nil when there is nothing to read."
  @spec for_entry(map) :: String.t() | nil
  def for_entry(%{sections: sections} = entry) do
    {poems, prose} =
      sections
      |> Enum.sort_by(& &1.position)
      |> Enum.reject(&(&1.kind == "illustration"))
      |> Enum.split_with(&(&1.kind in Spreads.right_kinds()))

    [title_line(entry) | Enum.map(prose ++ poems, &section_text/1)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
    |> case do
      "" -> nil
      text -> text
    end
  end

  @doc "A stable key for the text: the same prose narrates once."
  def hash(text) when is_binary(text) do
    :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  end

  @doc "Reading time at a narrator's pace, in seconds (about 14 characters a second on the 2026-10-15 samples)."
  def estimated_seconds(text) when is_binary(text), do: max(div(String.length(text), 14), 1)

  defp title_line(entry) do
    case present(entry.title) do
      nil -> nil
      title -> title |> plain() |> end_sentence()
    end
  end

  defp section_text(section) do
    [present(section.title) && section.title |> plain() |> end_sentence(), plain(section.body)]
    |> Enum.reject(&(&1 in [nil, false, ""]))
    |> Enum.join("\n\n")
  end

  @doc "Markdown flattened to the words a reader would hear."
  def plain(nil), do: ""

  def plain(text) when is_binary(text) do
    text
    # images (spot drawings) are nothing to read
    |> String.replace(~r/!\[[^\]]*\]\([^)]*\)/, "")
    # links keep their words
    |> String.replace(~r/\[([^\]]+)\]\([^)]*\)/, "\\1")
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace(~r/^\s{0,3}\#{1,6}\s+/m, "")
    |> String.replace(~r/^\s{0,3}>\s?/m, "")
    |> String.replace(~r/^\s*[-*+]\s+/m, "")
    |> String.replace(~r/(\*\*|__|\*|_|`)/, "")
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp end_sentence(""), do: ""

  defp end_sentence(line) do
    if String.ends_with?(line, [".", "!", "?", ":", "…"]), do: line, else: line <> "."
  end

  defp present(nil), do: nil
  defp present(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: s)
end
