defmodule TravelingPoet.ChangeStream.RegistryTest do
  use ExUnit.Case, async: true

  alias TravelingPoet.ChangeStream.Registry

  test "every Ecto schema in the app is streamed or explicitly excluded" do
    {:ok, modules} = :application.get_key(:traveling_poet, :modules)

    schemas =
      Enum.filter(modules, fn mod ->
        Code.ensure_loaded?(mod) and function_exported?(mod, :__schema__, 1) and
          is_binary(mod.__schema__(:source))
      end)

    decided = Enum.map(Registry.streamed(), &elem(&1, 1)) ++ Registry.excluded()
    undecided = schemas -- decided

    assert undecided == [],
           "new schema(s) with no change-stream decision: #{inspect(undecided)} — " <>
             "add to Registry @streamed or @excluded"
  end

  test "parents come before children" do
    order = Registry.entities()
    idx = fn e -> Enum.find_index(order, &(&1 == e)) end

    assert idx.("users") < idx.("poets")
    assert idx.("poets") < idx.("journal_entries")
    assert idx.("journal_entries") < idx.("journal_sections")
    assert idx.("journal_entries") < idx.("places")
    assert idx.("poets") < idx.("path_points")
    assert idx.("path_points") < idx.("places")
    assert idx.("poets") < idx.("poet_topics")
    assert idx.("poet_topics") < idx.("topic_excursions")
    assert idx.("journal_entries") < idx.("topic_excursions")
    assert idx.("journal_entries") < idx.("entry_finds")
    assert idx.("poets") < idx.("trips")
    assert idx.("trips") < idx.("itinerary_stops")
  end

  test "geocode_cache and the stream's own tables are not streamed" do
    refute "geocode_cache" in Registry.entities()
    refute "change_stream_events" in Registry.entities()
    refute "change_stream_endpoints" in Registry.entities()
  end
end
