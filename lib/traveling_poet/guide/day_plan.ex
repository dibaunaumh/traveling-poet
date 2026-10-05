defmodule TravelingPoet.Guide.DayPlan do
  @moduledoc """
  Plan my days (card-91): a reader's saved places laid out over a number of
  days. Pure.

  Places are grouped by where they are, so a day stays in one part of town
  (a few rounds of k-means on the coordinates, seeded far apart). Each day
  then runs the way a day does: breakfast first, then the sights and shops,
  dinner last, each leg to the nearest next place.
  """
  alias TravelingPoet.{Geo, MapsLinks}

  @rounds 8
  # A day with one place that close to another day's places is not a day.
  @fold_km 1.5

  @doc """
  `[%{day: 1, places: [...], route_url: url | nil}]`, at most `days` long
  (fewer when there are fewer places). Places without coordinates are left
  out; the caller can list them separately.
  """
  def plan(places, days) when is_integer(days) and days > 0 do
    mapped = Enum.filter(places, &(is_number(&1.lat) and is_number(&1.lng)))
    k = min(days, length(mapped))

    if k == 0 do
      []
    else
      mapped
      |> cluster(k)
      |> Enum.reject(&(&1 == []))
      |> fold_singles()
      |> Enum.sort_by(&west_edge/1)
      |> Enum.with_index(1)
      |> Enum.map(fn {group, n} ->
        ordered = order_day(group)
        %{day: n, places: ordered, route_url: MapsLinks.directions_url(ordered)}
      end)
    end
  end

  defp cluster(places, k) do
    seeds = seed(places, k)

    Enum.reduce(1..@rounds, seeds, fn _, centres ->
      places
      |> groups(centres)
      |> Enum.zip(centres)
      |> Enum.map(fn
        {[], centre} -> centre
        {group, _} -> centroid(group)
      end)
    end)
    |> then(&groups(places, &1))
  end

  # Farthest-point seeding: the first place, then each next seed the place
  # farthest from the seeds so far.
  defp seed([first | _] = places, k) do
    Enum.reduce(2..k//1, [point(first)], fn _, seeds ->
      far =
        Enum.max_by(places, fn p ->
          Enum.min(Enum.map(seeds, &dist(point(p), &1)))
        end)

      seeds ++ [point(far)]
    end)
  end

  defp groups(places, centres) do
    indexed = Enum.group_by(places, fn p -> nearest_index(point(p), centres) end)
    Enum.map(0..(length(centres) - 1), &Map.get(indexed, &1, []))
  end

  defp nearest_index(pt, centres) do
    centres |> Enum.with_index() |> Enum.min_by(fn {c, _} -> dist(pt, c) end) |> elem(1)
  end

  defp centroid(group) do
    n = length(group)
    {Enum.sum(Enum.map(group, & &1.lat)) / n, Enum.sum(Enum.map(group, & &1.lng)) / n}
  end

  # k-means fills every day it is given, so a few saves asked to cover more
  # days leave a lone cafe for a day of its own. Fold it into the nearest day
  # when that is a short walk away; the reader sees fewer, fuller days.
  defp fold_singles(groups) do
    single =
      Enum.find(groups, fn
        [place] -> nearest_other(groups, [place]) |> elem(1) <= @fold_km
        _ -> false
      end)

    case single do
      nil ->
        groups

      lone ->
        {target, _} = nearest_other(groups, lone)

        groups
        |> List.delete(lone)
        |> Enum.map(fn g -> if g == target, do: g ++ lone, else: g end)
        |> fold_singles()
    end
  end

  defp nearest_other(groups, [place] = lone) do
    groups
    |> List.delete(lone)
    |> Enum.map(fn g -> {g, Enum.min(Enum.map(g, &dist(point(&1), point(place))))} end)
    |> Enum.min_by(&elem(&1, 1), fn -> {nil, :infinity} end)
  end

  defp west_edge(group), do: group |> Enum.map(& &1.lng) |> Enum.min()

  # Breakfast, then the day, then dinner; each part walked nearest-first
  # from where the last one ended.
  defp order_day(group) do
    {mornings, rest} = Enum.split_with(group, &(&1.category == "cafe"))
    {dinners, middle} = Enum.split_with(rest, &(&1.category == "restaurant"))

    {ordered, _} =
      Enum.reduce([mornings, middle, dinners], {[], nil}, fn part, {acc, from} ->
        chain = chain(part, from)
        {acc ++ chain, List.last(chain) || from}
      end)

    ordered
  end

  defp chain([], _from), do: []
  defp chain(part, nil), do: chain_from(part, hd(part))

  defp chain(part, from) do
    start = Enum.min_by(part, &dist(point(&1), point(from)))
    chain_from(part, start)
  end

  defp chain_from(part, start) do
    Enum.reduce(1..(length(part) - 1)//1, {[start], List.delete(part, start)}, fn _,
                                                                                  {done, left} ->
      next = Enum.min_by(left, &dist(point(&1), point(List.last(done))))
      {done ++ [next], List.delete(left, next)}
    end)
    |> elem(0)
  end

  defp point(%{lat: lat, lng: lng}), do: {lat, lng}
  defp point({_, _} = pt), do: pt
  defp dist({a, b}, {c, d}), do: Geo.distance_km(a, b, c, d)
end
