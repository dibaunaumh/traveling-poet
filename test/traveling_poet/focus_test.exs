defmodule TravelingPoet.FocusTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.Topics

  test "focus is the reader's active place-based tastes, oldest first, at most three" do
    poet = poet_fixture(user_fixture())

    taste = fn domain, attrs ->
      Topics.create(poet.id, Map.merge(%{label: domain, domain: domain}, attrs))
    end

    taste.("books", %{})
    taste.("food", %{})
    taste.("gifts", %{})
    taste.("kids", %{status: "paused"})
    taste.("photography", %{})
    taste.("mountains", %{})
    taste.("art", %{})
    Topics.create(poet.id, %{label: "Embodied minds"})

    assert Enum.map(Topics.focus(poet.id), & &1.domain) == ~w(food photography mountains)
    assert hd(Topics.focus(poet.id)).name == "Food & drink"
  end
end
