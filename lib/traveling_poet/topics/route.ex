defmodule TravelingPoet.Topics.Route do
  @moduledoc """
  Where an excursion journey's nodes sit on the page: the topic, the venues
  it went to, and what each one brought back.

  Pure geometry, so the drawing itself is a dumb component and the layout can
  be tested without rendering. A topic has no coordinates, so its journey
  cannot go on a map; this is the shape that takes the map's place.

  Two layouts, because the two places it hangs are different shapes:

    * `:compact` for a notebook page, a column barely 300px wide: the topic
      at the top, the venues down a spine under it, no finds.
    * `:full` for the guide, wide: the topic at the left, venues in a column,
      each one's finds hanging off it.

  Coordinates are viewBox units, not pixels: the SVG scales to its container.
  """

  # full
  @root_x 108
  @venue_x 300
  @find_dot_x 624
  @width 960
  @row 34
  @block_padding 26
  @top 30

  # compact
  @c_width 470
  @c_spine_x 34
  @c_first_y 78
  @c_step 54

  @doc """
  Builds the diagram. `excursions` are `%{id, label, date, url, current?}` in
  the order they happened; `finds_by_excursion` maps an excursion id to
  `[%{id, name, url, kind}]` and is drawn only in `:full`.
  """
  def build(topic_label, excursions, finds_by_excursion \\ %{}, opts \\ []) do
    case Keyword.get(opts, :mode, :compact) do
      :full -> full(topic_label, excursions, finds_by_excursion)
      :compact -> compact(topic_label, excursions)
    end
  end

  defp compact(topic_label, excursions) do
    {venues, bottom} =
      excursions
      |> Enum.with_index(1)
      |> Enum.map_reduce(@c_first_y, fn {x, n}, y ->
        lines = wrap(x.label, 32, 2)

        venue = %{
          kind: :venue,
          id: x.id,
          n: n,
          label: Enum.join(lines, " "),
          lines: lines,
          sub: x.date && Calendar.strftime(x.date, "%b %-d"),
          href: x.url,
          current?: Map.get(x, :current?, false),
          x: @c_spine_x,
          y: y,
          label_x: @c_spine_x + 24,
          label_y: y - 1 - (length(lines) - 1) * 9,
          sub_y: y + 16 + (length(lines) - 1) * 9,
          finds: []
        }

        {venue, y + @c_step + (length(lines) - 1) * 20}
      end)

    height = max(bottom - @c_step + 60, 130)

    %{
      layout: :compact,
      width: @c_width,
      height: height,
      root: %{kind: :topic, label: clip(topic_label, 38), x: 18, y: 34, ring?: false},
      venues: venues,
      edges: spine(venues)
    }
  end

  # One line down the page, drawn with a little sway so it reads as a hand's.
  defp spine([]), do: []

  defp spine(venues) do
    first = List.first(venues)
    last = List.last(venues)
    mid_y = (first.y + last.y) / 2

    [
      %{
        kind: :spine,
        d: "M #{@c_spine_x} 48 Q #{@c_spine_x + 6} #{round(mid_y)} #{@c_spine_x} #{last.y}"
      }
    ]
  end

  defp full(topic_label, excursions, finds_by_excursion) do
    {venues, bottom} =
      excursions
      |> Enum.with_index(1)
      |> Enum.map_reduce(@top, fn {x, n}, y ->
        finds = Map.get(finds_by_excursion, x.id, [])
        lines = wrap(x.label, 30, 2)
        block = max(max(length(finds), 1) * @row, length(lines) * 22 + 10) + @block_padding
        centre = round(y + block / 2)

        venue = %{
          kind: :venue,
          id: x.id,
          n: n,
          label: Enum.join(lines, " "),
          lines: lines,
          sub: x.date && Calendar.strftime(x.date, "%b %-d"),
          href: x.url,
          current?: Map.get(x, :current?, false),
          x: @venue_x,
          y: centre,
          label_x: @venue_x + 26,
          label_y: centre - 2 - (length(lines) - 1) * 9,
          sub_y: centre + 15 + (length(lines) - 1) * 9,
          finds: place_finds(finds, y, block)
        }

        {venue, y + block}
      end)

    height = max(bottom + @top, 160)

    root = %{
      kind: :topic,
      label: clip(topic_label, 28),
      x: @root_x,
      y: round(height / 2),
      ring?: true
    }

    %{
      layout: :full,
      width: @width,
      height: height,
      root: root,
      venues: venues,
      edges: Enum.map(venues, &branch(root, &1)) ++ Enum.flat_map(venues, &twigs/1)
    }
  end

  defp place_finds([], _y, _block), do: []

  defp place_finds(finds, y, block) do
    top = y + (block - length(finds) * @row) / 2 + @row / 2

    finds
    |> Enum.with_index()
    |> Enum.map(fn {find, i} ->
      row_y = round(top + i * @row)

      %{
        kind: :find,
        id: find.id,
        label: clip(find.name, 34),
        sub: find.kind,
        href: find.url,
        dot_x: @find_dot_x,
        x: @find_dot_x + 16,
        y: row_y
      }
    end)
  end

  # A line with a little sag in it, the way a hand draws between two points.
  # Derived from the row, so the same journey always looks the same.
  defp branch(from, to) do
    mid_x = (from.x + to.x) / 2
    sag = rem(to.n, 2) * 8 - 4 + (to.y - from.y) / 12

    %{
      kind: :branch,
      d: "M #{from.x + 58} #{from.y} Q #{mid_x} #{round(from.y + sag)} #{to.x - 12} #{to.y}"
    }
  end

  defp twigs(venue) do
    Enum.map(venue.finds, fn find ->
      mid_x = (venue.x + find.dot_x) / 2

      %{
        kind: :twig,
        d:
          "M #{venue.x + 26} #{venue.y} Q #{round(mid_x)} #{round((venue.y + find.y) / 2)} " <>
            "#{find.dot_x - 6} #{find.y}"
      }
    end)
  end

  @doc """
  A name over as many lines as it needs, up to `max_lines`, broken between
  words. The last line is cut with an ellipsis when the name runs on: venues
  come back named "ECogS 2026 — International Conference on Embodied Cognitive
  Science", and one line of that in a notebook column is unreadable.
  """
  def wrap(nil, _per_line, _max_lines), do: [""]

  def wrap(text, per_line, max_lines) do
    text
    |> String.trim()
    |> String.split(~r/\s+/)
    |> Enum.reduce([""], fn word, [line | done] ->
      cond do
        line == "" -> [word | done]
        String.length(line) + 1 + String.length(word) <= per_line -> [line <> " " <> word | done]
        true -> [word, line | done]
      end
    end)
    |> Enum.reverse()
    |> then(fn lines ->
      case Enum.split(lines, max_lines) do
        {kept, []} -> kept
        {kept, _rest} -> List.update_at(kept, -1, &clip(&1 <> " …", per_line + 1))
      end
    end)
    |> Enum.map(&clip(&1, per_line + 2))
  end

  @doc "Text that fits the node, cut on a whole word with an ellipsis."
  def clip(nil, _max), do: ""

  def clip(text, max) do
    text = String.trim(text)

    if String.length(text) <= max do
      text
    else
      text |> String.slice(0, max - 1) |> String.replace(~r/\s+\S*$/u, "") |> Kernel.<>("…")
    end
  end
end
