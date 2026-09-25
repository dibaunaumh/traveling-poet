defmodule TravelingPoet.Journal.Paragraphs do
  @moduledoc """
  An entry's prose, paragraph by paragraph, each with a key the server and
  the browser both compute: the first 16 hex characters of the SHA-256 of
  the paragraph's visible text (markdown syntax and images dropped,
  whitespace collapsed). Sections are wiped and re-inserted whenever the
  poet re-puts an entry, so a paragraph is known by its words, as a feedback
  marker is by its quote; a revision keeps every unchanged paragraph's key.

  Only top-level paragraphs of prose sections: a poem's stanzas say more
  about poetry than about their subject, a tight list renders without <p>,
  and a line under 40 characters is a caption or a heading, not prose.
  """

  alias TravelingPoet.Journal.Section

  @prose ~w(description art_culture products kindness highlights)
  @min_length 40

  def prose_kinds, do: @prose

  @doc "`[%{key, text, section_kind}]` in reading order, one per paragraph."
  def of_sections(sections) do
    sections
    |> Enum.filter(&(&1.kind in @prose and is_binary(&1.body)))
    |> Enum.sort_by(& &1.position)
    |> Enum.flat_map(fn %Section{} = s ->
      s.body |> of_markdown() |> Enum.map(&Map.put(&1, :section_kind, s.kind))
    end)
    |> Enum.uniq_by(& &1.key)
  end

  @doc "The paragraphs of one markdown body, as `[%{key, text}]`."
  def of_markdown(markdown) when is_binary(markdown) do
    case MDEx.parse_document(markdown) do
      {:ok, doc} ->
        doc.nodes
        |> Enum.filter(&match?(%MDEx.Paragraph{}, &1))
        |> Enum.map(&normalize(text(&1)))
        |> Enum.filter(&(String.length(&1) >= @min_length))
        |> Enum.map(&%{key: key(&1), text: &1})

      _ ->
        []
    end
  end

  def of_markdown(_), do: []

  @doc """
  The key of a paragraph's visible text. The browser does the same to a
  rendered <p>'s textContent: collapse whitespace, trim, SHA-256, 16 hex.
  """
  def key(text),
    do:
      :crypto.hash(:sha256, normalize(text)) |> Base.encode16(case: :lower) |> binary_part(0, 16)

  defp normalize(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  # What a reader sees of a node: text and code as written, a line break as
  # a space, an image as nothing (it renders as an <img>, not as text).
  defp text(%MDEx.Text{literal: t}), do: t
  defp text(%MDEx.Code{literal: t}), do: t
  defp text(%MDEx.SoftBreak{}), do: " "
  defp text(%MDEx.LineBreak{}), do: " "
  defp text(%MDEx.Image{}), do: ""
  defp text(%{nodes: nodes}) when is_list(nodes), do: Enum.map_join(nodes, &text/1)
  defp text(_), do: ""
end
