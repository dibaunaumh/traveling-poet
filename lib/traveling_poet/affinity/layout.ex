defmodule TravelingPoet.Affinity.Layout do
  @moduledoc """
  The subject tree on a flat page (card-37): every topic at a fixed 2D point,
  so any taste profile can be drawn as dots on the same picture and two
  readers' pictures can be compared. A squarified treemap (as the village
  draws it), sized by how many topics each branch has rather than by any
  reader's data, so the layout never moves: subjects are regions, their
  subtopics sub-regions, and each topic the centre of its own tile.
  """

  alias TravelingPoet.Guide.PlaceTopics

  @width 1000
  @height 640
  # the strip at the top of each subject's region kept for its name
  @label_band 50

  def width, do: @width
  def height, do: @height

  @doc """
  `%{regions: [%{path, name, x, y, w, h}], points: %{path => {x, y}}}`:
  the 12 subjects as regions, every third-level topic as a point.
  """
  def layout do
    case :persistent_term.get({__MODULE__, :layout}, nil) do
      nil ->
        computed = compute()
        :persistent_term.put({__MODULE__, :layout}, computed)
        computed

      computed ->
        computed
    end
  end

  defp compute do
    tree = PlaceTopics.tree()
    rect = {0.0, 0.0, @width * 1.0, @height * 1.0}

    subjects =
      squarify(
        Enum.map(tree, &{&1, leaf_count(&1)}),
        rect
      )

    regions =
      Enum.map(subjects, fn {a, {x, y, w, h}} ->
        %{path: a["slug"], name: a["name"], x: x, y: y, w: w, h: h}
      end)

    points =
      for {a, arect} <- subjects,
          {b, brect} <-
            squarify(Enum.map(a["children"], &{&1, leaf_count(&1)}), below_label(arect)),
          {c, {x, y, w, h}} <- squarify(Enum.map(b["children"], &{&1, 1}), brect),
          into: %{} do
        {"#{a["slug"]}/#{b["slug"]}/#{c["slug"]}", {x + w / 2, y + h / 2}}
      end

    %{regions: regions, points: points}
  end

  defp below_label({x, y, w, h}), do: {x, y + @label_band, w, h - @label_band}

  defp leaf_count(%{"children" => children}) when is_list(children) and children != [],
    do: children |> Enum.map(&leaf_count/1) |> Enum.sum()

  defp leaf_count(_), do: 1

  @doc """
  Squarified treemap (Bruls, Huizing, van Wijk) of `[{item, value}]` into
  `{x, y, w, h}`; returns `[{item, rect}]`. Ties keep the tree's order.
  """
  def squarify(items, {_x, _y, w, h} = rect) do
    total = items |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    if total <= 0 do
      []
    else
      scale = w * h / total

      items
      |> Enum.with_index()
      |> Enum.sort_by(fn {{_item, v}, i} -> {-v, i} end)
      |> Enum.map(fn {{item, v}, _i} -> {item, v * scale} end)
      |> lay([], rect, [])
      |> Enum.reverse()
    end
  end

  defp lay([], [], _rect, out), do: out
  defp lay([], row, rect, out), do: layout_row(row, rect, out) |> elem(1)

  defp lay([next | rest] = queue, row, {_x, _y, w, h} = rect, out) do
    side = min(w, h)

    if row == [] or worst(row ++ [next], side) <= worst(row, side) do
      lay(rest, row ++ [next], rect, out)
    else
      {rect, out} = layout_row(row, rect, out)
      lay(queue, [], rect, out)
    end
  end

  defp worst(row, side) do
    areas = Enum.map(row, &elem(&1, 1))
    sum = Enum.sum(areas)
    max(side * side * Enum.max(areas) / (sum * sum), sum * sum / (side * side * Enum.min(areas)))
  end

  defp layout_row(row, {x, y, w, h}, out) do
    sum = row |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    if w >= h do
      rw = sum / h

      {out, _} =
        Enum.reduce(row, {out, y}, fn {item, area}, {acc, cy} ->
          rh = area / rw
          {[{item, {x, cy, rw, rh}} | acc], cy + rh}
        end)

      {{x + rw, y, w - rw, h}, out}
    else
      rh = sum / w

      {out, _} =
        Enum.reduce(row, {out, x}, fn {item, area}, {acc, cx} ->
          rw = area / rh
          {[{item, {cx, y, rw, rh}} | acc], cx + rw}
        end)

      {{x, y + rh, w, h - rh}, out}
    end
  end
end
