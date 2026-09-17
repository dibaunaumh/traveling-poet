defmodule TravelingPoet.Topics.RouteTest do
  use ExUnit.Case, async: true

  alias TravelingPoet.Topics.Route

  defp excursion(id, label, date, opts \\ []),
    do: %{
      id: id,
      label: label,
      date: date,
      url: opts[:url],
      current?: Keyword.get(opts, :current?, false)
    }

  test "the topic sits beside its venues, in the order they happened" do
    d =
      Route.build("Embodied minds", [
        excursion(1, "ECogS 2026", ~D[2026-09-09]),
        excursion(2, "Robotics workshop", ~D[2026-09-12], current?: true)
      ])

    assert d.root.label == "Embodied minds"
    assert [first, second] = d.venues
    assert {first.n, first.label, first.sub} == {1, "ECogS 2026", "Sep 9"}
    assert second.current?
    refute first.current?
    assert d.layout == :compact
    # a spine down the page: same x, in order, topic above them
    assert first.x == second.x and first.y < second.y and first.y > d.root.y
    assert [%{kind: :spine}] = d.edges
    assert Enum.all?(d.venues, &(&1.finds == []))
  end

  test "in full mode each venue's finds hang off it, inside its own block" do
    finds = %{
      1 => [
        %{id: 11, name: "Shanahan keynote", url: "https://x.example/1", kind: "talk"},
        %{id: 12, name: "Tani lecture", url: "https://x.example/2", kind: "talk"}
      ],
      2 => [%{id: 13, name: "An open hand kit", url: "https://x.example/3", kind: "product"}]
    }

    d =
      Route.build(
        "Embodied minds",
        [excursion(1, "ECogS 2026", ~D[2026-09-09]), excursion(2, "RSS", ~D[2026-09-12])],
        finds,
        mode: :full
      )

    assert d.layout == :full
    assert d.root.ring?
    [a, b] = d.venues
    assert length(a.finds) == 2 and length(b.finds) == 1
    assert Enum.map(a.finds, & &1.label) == ["Shanahan keynote", "Tani lecture"]
    assert hd(a.finds).x > a.x
    assert Enum.all?(a.finds, &(&1.y < b.y))
    assert hd(b.finds).y > List.last(a.finds).y
    assert Enum.count(d.edges, &(&1.kind == :branch)) == 2
    assert Enum.count(d.edges, &(&1.kind == :twig)) == 3
    assert d.height > 160
  end

  test "long names are cut on a word, and an empty journey still has a drawing" do
    assert Route.clip("An Alien Mind and the Long Road After It", 20) == "An Alien Mind and…"
    assert Route.clip("Short", 20) == "Short"

    d = Route.build("Kit airplanes", [])
    assert d.venues == [] and d.edges == []
    assert d.height == 130
    refute d.root.ring?
  end
end
