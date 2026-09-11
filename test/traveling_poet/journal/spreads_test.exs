defmodule TravelingPoet.Journal.SpreadsTest do
  use ExUnit.Case, async: true

  alias TravelingPoet.Journal.Spreads

  defp section(kind, position, media_id \\ nil),
    do: %{kind: kind, position: position, media_id: media_id, title: nil, body: "x"}

  test "nothing to read means no spreads" do
    assert Spreads.pack(nil, %{}, []) == []
  end

  test "words on the left in the poet's order, drawing then poem on the right" do
    entry = %{
      entry_date: ~D[2026-09-11],
      sections: [
        section("illustration", 0, 7),
        section("description", 1),
        section("poem", 2),
        section("products", 3),
        section("kindness", 4)
      ]
    }

    assert [%{key: "today", label: "Today", left: left, right: right}, %{key: "places"}] =
             Spreads.pack(entry, %{7 => %{id: 7}}, [], [], ~D[2026-09-11])

    assert Enum.map(left, fn {:section, s} -> {s.kind, s.position} end) ==
             [{"description", 1}, {"products", 3}, {"kindness", 4}]

    assert Enum.map(right, fn {:section, s} -> {s.kind, s.position} end) ==
             [{"illustration", 0}, {"poem", 2}]
  end

  test "an illustration section with no drawing is dropped; unclaimed drawings sit before the poem" do
    entry = %{
      sections: [section("description", 0), section("illustration", 1, 9), section("poem", 2)]
    }

    loose = %{id: 11}

    [%{right: right}, _places] = Spreads.pack(entry, %{}, [loose])

    assert right == [{:media, loose}, {:section, section("poem", 2)}]
  end

  test "Places follows Today: the map on the left, the day's stops on the right, even when empty" do
    entry = %{sections: [section("description", 0)]}
    stops = [%{id: 1, name: "Cafe"}, %{id: 2, name: "Bridge"}]

    assert [%{key: "today"}, %{key: "places", label: "Places", left: [{:map, nil}], right: right}] =
             Spreads.pack(entry, %{}, [], stops)

    assert right == Enum.map(stops, &{:place, &1})

    assert [_, %{key: "places", right: []}] = Spreads.pack(entry, %{}, [])
  end

  test "an earlier entry's tab reads its date, never Today" do
    entry = %{entry_date: ~D[2026-09-04], sections: []}

    assert [%{key: "today", label: "Sep 4"}, _] = Spreads.pack(entry, %{}, [], [], ~D[2026-09-11])
    assert [%{label: "Today"}, _] = Spreads.pack(entry, %{}, [], [], ~D[2026-09-04])
  end

  test "pick falls back to the first spread for an unknown or missing key" do
    spreads = [%{key: "today"}, %{key: "places"}]

    assert Spreads.pick(spreads, "places") == %{key: "places"}
    assert Spreads.pick(spreads, "garbage") == %{key: "today"}
    assert Spreads.pick(spreads, nil) == %{key: "today"}
    assert Spreads.pick([], "today") == nil
  end
end
