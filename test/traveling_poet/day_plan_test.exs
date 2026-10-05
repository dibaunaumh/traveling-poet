defmodule TravelingPoet.DayPlanTest do
  use ExUnit.Case, async: true

  alias TravelingPoet.Guide.DayPlan
  alias TravelingPoet.MapsLinks

  defp place(name, category, lat, lng), do: %{name: name, category: category, lat: lat, lng: lng}

  # Two parts of Kraków about 2 km apart: the Old Town and Kazimierz.
  defp old_town,
    do: [
      place("Charlotte", "cafe", 50.0646, 19.9358),
      place("Cloth Hall", "landmark", 50.0617, 19.9373),
      place("Pod Baranami", "restaurant", 50.0605, 19.9355)
    ]

  defp kazimierz,
    do: [
      place("Massolit", "cafe", 50.0518, 19.9452),
      place("Starka", "restaurant", 50.0510, 19.9440),
      place("Old Synagogue", "attraction", 50.0515, 19.9489)
    ]

  test "places are grouped by part of town" do
    plan = DayPlan.plan(Enum.shuffle(old_town() ++ kazimierz()), 2)

    assert length(plan) == 2

    groups = Enum.map(plan, fn day -> day.places |> Enum.map(& &1.name) |> MapSet.new() end)
    assert MapSet.new(Enum.map(old_town(), & &1.name)) in groups
    assert MapSet.new(Enum.map(kazimierz(), & &1.name)) in groups
  end

  test "a lone place a short walk from another day joins it" do
    # Six places in two quarters, asked for three days: no day of one cafe.
    plan = DayPlan.plan(old_town() ++ kazimierz(), 3)

    assert length(plan) == 2
    assert Enum.all?(plan, &(length(&1.places) == 3))
  end

  test "a day starts with coffee and ends with dinner" do
    [day] = DayPlan.plan(Enum.reverse(kazimierz()), 1)

    assert hd(day.places).name == "Massolit"
    assert List.last(day.places).name == "Starka"
    assert day.route_url =~ "https://www.google.com/maps/dir/?"
    assert day.route_url =~ "travelmode=walking"
  end

  test "never more days than places, and unmapped places are left out" do
    plan = DayPlan.plan([hd(old_town()), place("Somewhere", "shop", nil, nil)], 4)

    assert [%{day: 1, places: [%{name: "Charlotte"}], route_url: nil}] = plan
    assert DayPlan.plan([], 3) == []
  end

  test "the route runs through the stops in order" do
    url = MapsLinks.directions_url(old_town())
    query = url |> URI.parse() |> Map.get(:query) |> URI.decode_query()

    assert query["origin"] == "50.0646,19.9358"
    assert query["waypoints"] == "50.0617,19.9373"
    assert query["destination"] == "50.0605,19.9355"
  end
end
