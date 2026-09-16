defmodule TravelingPoet.Books.Index do
  @moduledoc """
  The back-of-the-book index: where to find a place, a poem, a topic.

  Pure. Terms are sorted for reading, not for machines (case folded), and
  each points at the day pages it appears on by anchor, so the same index
  works with page numbers under paged.js and as links on screen. Books the
  poet was reading are listed too; the poet keeps only its current list, so
  that section says what it was reading, not when.
  """

  alias TravelingPoet.Topics

  @poem_term_max 60

  @type ref :: %{chapter: pos_integer, anchor: String.t(), date: Date.t()}
  @type t :: %{
          places: [%{term: String.t(), refs: [ref]}],
          poems: [%{term: String.t(), ref: ref}],
          books: [%{term: String.t(), author: String.t() | nil}],
          topics: [%{term: String.t(), refs: [ref]}]
        }

  @spec build([map], map) :: t
  def build(chapters, poet) do
    %{
      places: places(chapters),
      poems: poems(chapters),
      books: books(poet),
      topics: topics(chapters)
    }
  end

  defp places(chapters) do
    chapters
    |> Enum.flat_map(fn ch ->
      Enum.flat_map(ch.days, fn day ->
        day.bundle.places
        |> Enum.map(& &1.name)
        |> Enum.reject(&blank?/1)
        |> Enum.uniq_by(&fold/1)
        |> Enum.map(&{&1, ref(ch, day)})
      end)
    end)
    |> group_terms()
  end

  defp poems(chapters) do
    chapters
    |> Enum.flat_map(fn ch ->
      Enum.flat_map(ch.days, fn day ->
        day.entry.sections
        |> Enum.filter(&(&1.kind == "poem"))
        |> Enum.map(&poem_term/1)
        |> Enum.reject(&blank?/1)
        |> Enum.map(&%{term: &1, ref: ref(ch, day)})
      end)
    end)
    |> Enum.sort_by(&fold(&1.term))
  end

  defp books(%{currently_reading: %{"items" => items}}) when is_list(items) do
    items
    |> Enum.flat_map(fn
      %{"title" => title} = item when is_binary(title) and title != "" ->
        [%{term: title, author: item["author"]}]

      _ ->
        []
    end)
    |> Enum.uniq_by(&fold(&1.term))
    |> Enum.sort_by(&fold(&1.term))
  end

  defp books(_poet), do: []

  defp topics(chapters) do
    chapters
    |> Enum.flat_map(fn ch ->
      Enum.flat_map(ch.days, fn day ->
        case Topics.excursion_of(day.entry) do
          %{topic: %{label: label}} when is_binary(label) -> [{label, ref(ch, day)}]
          _ -> []
        end
      end)
    end)
    |> group_terms()
  end

  defp group_terms(pairs) do
    pairs
    |> Enum.group_by(fn {term, _ref} -> fold(term) end)
    |> Enum.map(fn {_key, [{term, _} | _] = group} ->
      %{term: term, refs: group |> Enum.map(&elem(&1, 1)) |> Enum.uniq_by(& &1.anchor)}
    end)
    |> Enum.sort_by(&fold(&1.term))
  end

  defp ref(chapter, day), do: %{chapter: chapter.number, anchor: day.anchor, date: day.date}

  # A poem is listed by its title, else its first line, shorn of markdown.
  defp poem_term(%{title: title}) when is_binary(title) and title != "", do: title

  defp poem_term(%{body: body}) when is_binary(body) do
    body
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.replace(&1, ~r/^[#>*_\-\s]+|[*_]+$/, ""))
    |> Enum.find("", &(&1 != ""))
    |> truncate(@poem_term_max)
  end

  defp poem_term(_section), do: nil

  defp truncate(text, max) when byte_size(text) <= max, do: text

  defp truncate(text, max) do
    cut = String.slice(text, 0, max)

    case String.split(cut, ~r/\s+/) do
      [_only] -> cut <> "..."
      words -> (words |> Enum.drop(-1) |> Enum.join(" ")) <> "..."
    end
  end

  defp fold(term), do: term |> String.trim() |> String.downcase()

  defp blank?(nil), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
end
