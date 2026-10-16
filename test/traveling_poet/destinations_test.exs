defmodule TravelingPoet.Geocoder.DestinationsTest do
  use ExUnit.Case, async: true

  alias TravelingPoet.Geocoder.Destinations

  defp hit(name, kind, city \\ nil),
    do: %{place_name: name, kind: kind, city: city, lat: 1.0, lng: 2.0, country_code: "XX"}

  # What Nominatim answers, by query (checked live 2026-10-16): a list sent
  # whole is noise or nothing, a qualified place is found whole.
  defp answers,
    do: %{
      "Lisbon" => [hit("Lisboa, Portugal", "city", "Lisboa")],
      "Porto" => [hit("Porto, Portugal", "city", "Porto")],
      "Kyoto" => [hit("Kyoto, Japan", "city", "Kyoto")],
      "Portugal" => [hit("Portugal", "country")],
      "Texas" => [hit("Texas, United States", "state")],
      "Paris" => [hit("Paris, France", "city", "Paris")],
      "Paris, Texas" => [hit("Paris, Lamar County, Texas, United States", "city", "Paris")],
      "Lisbon, Portugal" => [hit("Lisboa, Portugal", "city", "Lisboa")],
      "Lisbon, Porto" => [hit("Synopsys Lisboa, Edifício 4, Lisboa", "office")],
      "Tuscany" => [hit("Tuscany, Italy", "state")]
    }

  defp search(query) do
    send(self(), {:searched, query})
    {:ok, Map.get(answers(), query, [])}
  end

  test "one name is one place" do
    assert {:place, [%{city: "Lisboa"}]} = Destinations.resolve("Lisbon", &search/1)
    assert {:none, "Atlantis"} = Destinations.resolve("Atlantis", &search/1)
    assert {:none, ""} = Destinations.resolve("  ", &search/1)
  end

  test "a country or a state after the comma qualifies one place; the list is not sent whole as a route" do
    assert {:place, [%{place_name: "Paris, Lamar County" <> _}]} =
             Destinations.resolve("Paris, Texas", &search/1)

    assert_received {:searched, "Texas"}
    assert_received {:searched, "Paris, Texas"}
    refute_received {:searched, "Paris"}

    assert {:place, [%{city: "Lisboa"}]} = Destinations.resolve("Lisbon, Portugal", &search/1)
  end

  test "a city after the comma makes a route, each part looked up on its own, in order" do
    assert {:route, [%{city: "Lisboa"}, %{city: "Porto"}], []} =
             Destinations.resolve("Lisbon, Porto", &search/1)

    # never the whole string, which Nominatim answers with an office park
    refute_received {:searched, "Lisbon, Porto"}

    assert {:route, [%{city: "Lisboa"}, %{city: "Kyoto"}, %{city: "Porto"}], []} =
             Destinations.resolve("Lisbon; Kyoto, Porto", &search/1)
  end

  test "a part nobody can find is reported, and a region can be a stop" do
    assert {:route, [%{city: "Lisboa"}, %{city: "Porto"}], ["Atlantis"]} =
             Destinations.resolve("Lisbon, Atlantis, Porto", &search/1)

    assert {:route, [%{city: "Lisboa"}], ["Atlantis", "Mu"]} =
             Destinations.resolve("Lisbon, Atlantis, Mu", &search/1)

    assert {:route, [%{city: "Lisboa"}, %{place_name: "Tuscany, Italy"}], []} =
             Destinations.resolve("Lisbon, Tuscany", fn
               "Lisbon, Tuscany" -> {:ok, []}
               q -> search(q)
             end)

    assert {:none, "Atlantis, Mu"} = Destinations.resolve("Atlantis, Mu", &search/1)
  end

  test "a qualified place the geocoder cannot find whole falls back to its parts, countries dropped" do
    assert {:place, [%{city: "Lisboa"}]} =
             Destinations.resolve("Lisbon, Portugal", fn
               "Lisbon, Portugal" -> {:ok, []}
               q -> search(q)
             end)
  end

  test "an unreachable geocoder is an error, not an empty answer" do
    assert {:error, "down"} = Destinations.resolve("Lisbon", fn _ -> {:error, "down"} end)
    assert {:error, "down"} = Destinations.resolve("Lisbon, Porto", fn _ -> {:error, "down"} end)
  end
end
