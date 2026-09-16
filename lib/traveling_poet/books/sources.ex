defmodule TravelingPoet.Books.Sources do
  @moduledoc """
  Every link a day cites, gathered for the page's footnotes.

  On screen a source is a click away; on paper it has to be printed. This
  collects them from wherever the poet left them (the entry's own sources,
  a section's source line, the reference every drawing was drawn from, a
  place's page, a find's page), in reading order, one line per distinct URL.
  Pure: takes an `EntryBundle`, returns `[%{label, url, kind}]`.
  """

  @type source :: %{label: String.t(), url: String.t(), kind: String.t()}

  @spec for_bundle(map) :: [source]
  def for_bundle(%{entry: nil}), do: []

  def for_bundle(bundle) do
    entry = bundle.entry

    (entry_sources(entry) ++
       section_sources(entry.sections) ++
       drawing_sources(bundle) ++
       place_sources(bundle.places) ++
       find_sources(bundle.finds))
    |> Enum.filter(&http?(&1.url))
    |> Enum.uniq_by(&String.trim(&1.url))
  end

  # The agent writes `sources` as `%{"items" => [%{"url", "label"}]}`, the same
  # shape as a drawing's; older entries may carry a bare list or nothing.
  defp entry_sources(%{sources: sources}), do: items(sources, "entry")
  defp entry_sources(_entry), do: []

  defp section_sources(sections) do
    Enum.flat_map(sections, fn s ->
      meta = Map.get(s, :metadata) || %{}

      case meta["source_url"] do
        url when is_binary(url) ->
          [%{label: meta["source_label"] || label_from(s) || url, url: url, kind: "section"}]

        _ ->
          []
      end
    end)
  end

  # The main drawing, drawings no section claimed, and every spot drawing:
  # each was drawn from a real photo and says so.
  defp drawing_sources(bundle) do
    illustrations =
      bundle.entry.sections
      |> Enum.filter(&(&1.kind == "illustration"))
      |> Enum.flat_map(fn s -> List.wrap(Map.get(bundle.media, s.media_id)) end)

    spots = bundle.spot_media |> Map.values() |> Enum.sort_by(& &1.id)

    (illustrations ++ bundle.extra_media ++ spots)
    |> Enum.flat_map(fn media -> items(Map.get(media, :sources), "drawing") end)
  end

  defp place_sources(places) do
    for %{source_url: url} = p when is_binary(url) <- places,
        do: %{label: p.name, url: url, kind: "place"}
  end

  defp find_sources(finds) do
    for %{url: url} = f when is_binary(url) <- finds,
        do: %{label: f.name, url: url, kind: "find"}
  end

  defp items(%{"items" => items}, kind) when is_list(items), do: items(items, kind)

  defp items(items, kind) when is_list(items) do
    Enum.flat_map(items, fn
      %{"url" => url} = item when is_binary(url) ->
        [%{label: item["label"] || url, url: url, kind: kind}]

      %{url: url} = item when is_binary(url) ->
        [%{label: Map.get(item, :label) || url, url: url, kind: kind}]

      url when is_binary(url) ->
        [%{label: url, url: url, kind: kind}]

      _ ->
        []
    end)
  end

  defp items(_other, _kind), do: []

  defp label_from(%{title: title}) when is_binary(title) and title != "", do: title
  defp label_from(_section), do: nil

  defp http?(url) when is_binary(url), do: String.starts_with?(url, ["http://", "https://"])
  defp http?(_url), do: false
end
