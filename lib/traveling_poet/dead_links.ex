defmodule TravelingPoet.DeadLinks do
  @moduledoc """
  Keeps dead links out of what readers see, without failing the poet's call.

  `LinkCheck` already gates the links a poet names on purpose (a section's
  `source_url`, a place, a find, a drawing's references). Two kinds reached
  readers unchecked: the entry's own grounding `sources` (printed as the
  book's footnotes) and Markdown links inside section prose. The search eval
  found about 6% of the URLs Sonar cites are dead, and a poet copies them.

  Both are forgiving here, like `put_places`: a dead source is dropped, a
  dead link in prose loses its link but keeps its words, and the poet is told
  which. Unlinking keeps the rendered text identical, so feedback-marker text
  offsets are unaffected.
  """

  alias TravelingPoet.LinkCheck

  @concurrency 6
  @max_checked 20

  # [text](url) or [text](url "title"), not preceded by "!" (images are
  # app /media only and handled by the renderer).
  @inline ~r/(?<!!)\[([^\]]*)\]\(\s*<?(https?:\/\/[^\s)>]+)>?(?:\s+"[^"]*")?\s*\)/
  @autolink ~r/<(https?:\/\/[^\s>]+)>/

  @doc """
  The URLs among `urls` that are dead. At most #{@max_checked} distinct http(s)
  URLs are probed, concurrently; a probe that times out counts as alive.
  """
  def dead(urls) do
    urls
    |> Enum.filter(&http?/1)
    |> Enum.uniq()
    |> Enum.take(@max_checked)
    |> Task.async_stream(&{&1, LinkCheck.check(&1)},
      max_concurrency: @concurrency,
      timeout: 15_000,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, {_url, :ok}} -> []
      {:ok, {url, _dead}} -> [url]
      {:exit, _} -> []
    end)
    |> MapSet.new()
  end

  @doc """
  Drops dead URLs from an entry's `sources` (`%{"items" => [%{"url", ...}]}`,
  or a bare list). Returns `{sources, dropped_urls}`.
  """
  def prune_sources(%{"items" => items} = sources) when is_list(items) do
    {kept, dropped} = prune_items(items)
    {Map.put(sources, "items", kept), dropped}
  end

  def prune_sources(items) when is_list(items), do: prune_items(items)
  def prune_sources(other), do: {other, []}

  defp prune_items(items) do
    dead = items |> Enum.map(&item_url/1) |> dead()
    {kept, gone} = Enum.split_with(items, &(not MapSet.member?(dead, item_url(&1))))
    {kept, Enum.map(gone, &item_url/1)}
  end

  defp item_url(%{"url" => url}), do: url
  defp item_url(url) when is_binary(url), do: url
  defp item_url(_), do: nil

  @doc "The http(s) URLs linked from a Markdown body."
  def body_links(body) when is_binary(body) do
    Enum.map(Regex.scan(@inline, body), &Enum.at(&1, 2)) ++
      Enum.map(Regex.scan(@autolink, body), &Enum.at(&1, 1))
  end

  def body_links(_), do: []

  @doc "Replaces links to any URL in `dead` with their text (autolinks with the bare URL)."
  def unlink(body, dead) when is_binary(body) do
    body
    |> then(
      &Regex.replace(@inline, &1, fn whole, text, url ->
        if MapSet.member?(dead, url), do: text, else: whole
      end)
    )
    |> then(
      &Regex.replace(@autolink, &1, fn whole, url ->
        if MapSet.member?(dead, url), do: url, else: whole
      end)
    )
  end

  def unlink(body, _dead), do: body

  @doc """
  Unlinks dead links across agent section params (maps with a `"body"`).
  Returns `{sections, unlinked_urls}`.
  """
  def unlink_sections(sections) when is_list(sections) do
    dead =
      sections
      |> Enum.flat_map(&body_links(body_of(&1)))
      |> dead()

    if MapSet.size(dead) == 0 do
      {sections, []}
    else
      {Enum.map(sections, &put_body(&1, unlink(body_of(&1), dead))), MapSet.to_list(dead)}
    end
  end

  defp body_of(%{"body" => b}), do: b
  defp body_of(%{body: b}), do: b
  defp body_of(_), do: nil

  defp put_body(%{"body" => _} = s, b), do: Map.put(s, "body", b)
  defp put_body(%{body: _} = s, b), do: Map.put(s, :body, b)
  defp put_body(s, _b), do: s

  defp http?(url) when is_binary(url), do: String.starts_with?(url, ["http://", "https://"])
  defp http?(_), do: false
end
