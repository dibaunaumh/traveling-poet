defmodule TravelingPoet.Hotels.Rank do
  @moduledoc """
  Orders hotels by value, location and cost together (card-92). Pure.

  Location is the part no booking site can do: how many of the poet's
  places (the ones it chose for this reader's tastes) lie within a short
  walk of the hotel. Value is the guest rating. Cost is the price against
  the others found. Each is scaled 0-1 within the results, then weighed.
  """
  alias TravelingPoet.Geo

  @walk_km 0.8
  @weights %{location: 0.4, rating: 0.35, cost: 0.25}

  @doc """
  The hotels, best first, each with `near` (the poet's places within a
  short walk), `area` (the nearest weighed area's name) and `score`.
  """
  def rank(hotels, places, areas \\ []) do
    annotated =
      Enum.map(hotels, fn h ->
        Map.merge(h, %{near: near(h, places), area: nearest_area(h, areas)})
      end)

    max_near = annotated |> Enum.map(& &1.near) |> Enum.max(fn -> 0 end)
    prices = Enum.map(annotated, & &1.per_night)
    {lo, hi} = if prices == [], do: {0, 0}, else: Enum.min_max(prices)

    annotated
    |> Enum.map(fn h ->
      location = if max_near > 0, do: h.near / max_near, else: 0.0
      rating = if is_number(h.rating), do: min(h.rating / 10, 1.0), else: 0.0
      cost = if hi > lo, do: 1 - (h.per_night - lo) / (hi - lo), else: 1.0

      score =
        @weights.location * location + @weights.rating * rating + @weights.cost * cost

      Map.put(h, :score, Float.round(score, 3))
    end)
    |> Enum.sort_by(&(-&1.score))
  end

  defp near(h, places) do
    Enum.count(places, fn p ->
      is_number(p.lat) and is_number(p.lng) and
        Geo.distance_km(h.lat, h.lng, p.lat, p.lng) <= @walk_km
    end)
  end

  defp nearest_area(_h, []), do: nil

  defp nearest_area(h, areas) do
    areas
    |> Enum.filter(&(is_number(&1.lat) and is_number(&1.lng)))
    |> Enum.min_by(&Geo.distance_km(h.lat, h.lng, &1.lat, &1.lng), fn -> nil end)
    |> case do
      nil -> nil
      area -> if Geo.distance_km(h.lat, h.lng, area.lat, area.lng) <= 1.2, do: area.name
    end
  end
end
