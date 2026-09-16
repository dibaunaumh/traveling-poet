defmodule TravelingPoet.Books.Quotes do
  @moduledoc """
  Pull quotes the poet chooses from its own journal, held to one rule: a
  quote is printed only if those words are on the page it points at.

  A model asked to "pick a line" will happily improve the line, merge two,
  or remember one it never wrote. So the poet is handed its actual lines
  (`quotables/1`), and whatever it sends back is checked against the stored
  entry of the date it names (`validate/2`). The comparison forgives what a
  copy legitimately changes (curly quotes, dashes, spacing, markdown
  emphasis, a trimmed full stop, case) and nothing else. Unmatched quotes are
  dropped and reported, never rendered. The book re-checks at render time
  (`still_present/2`), so a quote from an entry revised since is dropped too.

  Pure: works on a `Books.Manuscript`.
  """

  @max_quotes 8
  @max_chars 240
  @min_chars 12
  @per_day_sentences 6
  @prose_kinds ~w(description poem art_culture products kindness highlights)
  # Punctuation a copied line may gain or lose at its ends: the quote marks
  # around it, a full stop. A character class, not a string: String.trim/2
  # strips a whole repeated string, which is not what this needs.
  @edge_punct ~r/\A[\s"'.,;:!?()\[\]-]+|[\s"'.,;:!?()\[\]-]+\z/u

  def max_quotes, do: @max_quotes
  def max_chars, do: @max_chars

  @doc """
  The lines the poet may quote, per day: every line of its poems, and the
  first sentences of its description. Plain text, markdown removed.
  """
  def quotables(manuscript) do
    for chapter <- manuscript.chapters, day <- chapter.days, into: %{} do
      poems =
        day.entry.sections
        |> Enum.filter(&(&1.kind == "poem"))
        |> Enum.flat_map(&lines/1)

      sentences =
        day.entry.sections
        |> Enum.filter(&(&1.kind == "description"))
        |> Enum.flat_map(&sentences/1)
        |> Enum.take(@per_day_sentences)

      {day.date, %{poem_lines: poems, sentences: sentences}}
    end
  end

  @doc """
  Checks what the poet submitted. Each item names an `entry_date` (ISO) and
  the `text`. Returns `{accepted, dropped}`: accepted as
  `%{"entry_date" => iso, "text" => text}` in the order given, dropped with
  a `"reason"` the poet can act on.
  """
  def validate(submitted, manuscript) when is_list(submitted) do
    days = days_by_date(manuscript)

    {accepted, dropped, _seen} =
      Enum.reduce(submitted, {[], [], MapSet.new()}, fn item, {acc, drop, seen} ->
        date_str = field(item, "entry_date")
        text = item |> field("text") |> to_trimmed()

        case check(date_str, text, days, seen, length(acc)) do
          {:ok, key} ->
            {[%{"entry_date" => date_str, "text" => text} | acc], drop, MapSet.put(seen, key)}

          {:error, reason} ->
            {acc, [%{"entry_date" => date_str, "text" => text, "reason" => reason} | drop], seen}
        end
      end)

    {Enum.reverse(accepted), Enum.reverse(dropped)}
  end

  def validate(_other, _manuscript), do: {[], []}

  @doc "The stored quotes whose words are still on their page, as `validate/2` would accept them."
  def still_present(quotes, manuscript) when is_list(quotes) do
    quotes |> validate(manuscript) |> elem(0)
  end

  def still_present(_quotes, _manuscript), do: []

  defp check(date_str, text, days, seen, accepted_count) do
    with {:ok, date} <- parse_date(date_str),
         {:ok, day} <- fetch_day(days, date),
         :ok <- length_ok(text),
         needle = normalize(text) |> trim_edges(),
         :ok <- not_seen(seen, {date, needle}),
         :ok <- room(accepted_count),
         :ok <- on_page(day, needle) do
      {:ok, {date, needle}}
    end
  end

  defp parse_date(s) when is_binary(s) do
    case Date.from_iso8601(s) do
      {:ok, d} -> {:ok, d}
      _ -> {:error, "entry_date must be a date like 2026-09-01"}
    end
  end

  defp parse_date(_), do: {:error, "entry_date is required"}

  defp fetch_day(days, date) do
    case Map.fetch(days, date) do
      {:ok, day} -> {:ok, day}
      :error -> {:error, "no published entry on that date"}
    end
  end

  defp length_ok(""), do: {:error, "text is required"}

  defp length_ok(text) do
    n = String.length(text)

    cond do
      n > @max_chars -> {:error, "longer than #{@max_chars} characters: choose a shorter line"}
      String.length(normalize(text)) < @min_chars -> {:error, "too short to stand on a page"}
      true -> :ok
    end
  end

  defp not_seen(seen, key),
    do: if(MapSet.member?(seen, key), do: {:error, "already chosen"}, else: :ok)

  defp room(n) when n >= @max_quotes, do: {:error, "only #{@max_quotes} quotes fit the book"}
  defp room(_n), do: :ok

  defp on_page(day, needle) do
    haystack =
      day.entry.sections
      |> Enum.filter(&(&1.kind in @prose_kinds))
      |> Enum.map_join("\n", &(plain(&1.body) |> normalize()))

    if needle != "" and String.contains?(haystack, needle),
      do: :ok,
      else: {:error, "not found word for word in that day's entry: quote it exactly"}
  end

  defp days_by_date(manuscript) do
    for chapter <- manuscript.chapters, day <- chapter.days, into: %{}, do: {day.date, day}
  end

  defp lines(%{body: body}) when is_binary(body) do
    body
    |> plain()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp lines(_section), do: []

  defp sentences(%{body: body}) when is_binary(body) do
    body
    |> plain()
    |> String.replace(~r/\s+/u, " ")
    |> String.split(~r/(?<=[.!?])\s+/u)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(String.length(&1) >= @min_chars and String.length(&1) <= @max_chars))
  end

  defp sentences(_section), do: []

  @doc false
  # Markdown to the words a reader sees: images dropped, links to their
  # text, emphasis and heading marks removed. Line breaks kept.
  def plain(nil), do: ""

  def plain(body) when is_binary(body) do
    body
    |> String.replace(~r/!\[[^\]]*\]\([^)]*\)/u, "")
    |> String.replace(~r/\[([^\]]*)\]\([^)]*\)/u, "\\1")
    |> String.replace(~r/^\s{0,3}(#+|>)\s*/um, "")
    |> String.replace(~r/[*_`]/u, "")
  end

  @doc false
  # What a faithful copy may differ by: typography, spacing, case.
  def normalize(text) when is_binary(text) do
    text
    |> plain()
    |> String.replace(["‘", "’", "‚", "′"], "'")
    |> String.replace(["“", "”", "„", "″"], "\"")
    |> String.replace(["–", "—", "−"], "-")
    |> String.replace("…", "...")
    |> String.replace(" ", " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.downcase()
  end

  defp trim_edges(text), do: Regex.replace(@edge_punct, text, "")

  defp field(%{} = item, key), do: Map.get(item, key) || Map.get(item, String.to_atom(key))
  defp field(_item, _key), do: nil

  defp to_trimmed(s) when is_binary(s), do: String.trim(s)
  defp to_trimmed(_), do: ""
end
