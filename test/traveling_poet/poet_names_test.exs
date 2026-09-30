defmodule TravelingPoet.PoetNamesTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.Poets
  alias TravelingPoet.Poets.Presets

  test "a preset name another poet already has is not offered" do
    poet_fixture(user_fixture(), %{name: " ferris lune "})
    taken = Poets.taken_names()

    for _ <- 1..200 do
      refute Presets.random_name(nil, taken) == "Ferris Lune"
    end
  end

  test "with every preset taken, a new name is made from two of them" do
    taken = MapSet.new(Presets.names(), &Presets.normalize/1)
    name = Presets.random_name(nil, taken)

    refute name in Presets.names()
    [first, last] = String.split(name)
    assert Enum.any?(Presets.names(), &String.starts_with?(&1, first <> " "))
    assert Enum.any?(Presets.names(), &String.ends_with?(&1, " " <> last))
  end

  test "shuffling never shows the same name twice in a row" do
    for _ <- 1..50, do: refute(Presets.random_name("Wren") == "Wren")
  end
end
