defmodule TravelingPoet.BookmarksTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Bookmarks, Guide, Poets}

  setup do
    reader = user_fixture()
    author = user_fixture()
    poet = poet_fixture(author, %{is_public: true, name: "Hilma"})
    entry = published_entry_fixture(poet, %{entry_date: ~D[2026-09-28]})
    place = place_fixture(poet, entry, %{name: "Tsuruya", lat: 36.25, lng: 136.9})
    %{reader: reader, author: author, poet: poet, entry: entry, place: place}
  end

  test "save, see it marked, and unsave", %{reader: reader, place: place} do
    assert {:ok, :saved} = Bookmarks.toggle(reader.id, "place", place.id)
    assert Bookmarks.saved?(Bookmarks.keys(reader.id), place)
    assert Bookmarks.count(reader.id) == 1

    assert {:ok, :removed} = Bookmarks.toggle(reader.id, "place", place.id)
    refute Bookmarks.saved?(Bookmarks.keys(reader.id), place)
  end

  test "a private poet's place is not saveable by anyone else, but is by its own reader",
       %{reader: reader, author: author, poet: poet, place: place} do
    {:ok, _} = Poets.update_poet(poet, %{is_public: false})
    assert {:error, :not_found} = Bookmarks.toggle(reader.id, "place", place.id)
    assert {:ok, :saved} = Bookmarks.toggle(author.id, "place", place.id)
  end

  # A poet's re-put replaces a page's places wholesale, new ids and all.
  test "a bookmark survives the poet revising the page", %{
    reader: reader,
    entry: entry,
    place: place
  } do
    {:ok, :saved} = Bookmarks.toggle(reader.id, "place", place.id)

    [again] = Guide.replace_places(entry, [%{name: "Tsuruya", category: "restaurant"}]) |> elem(1)
    assert again.id != place.id

    assert [%{item: item, live?: true}] = Bookmarks.list(reader.id)
    assert item.id == again.id
  end

  test "an item gone from its page stands in from the saved copy",
       %{reader: reader, entry: entry, place: place} do
    {:ok, :saved} = Bookmarks.toggle(reader.id, "place", place.id)
    {:ok, _} = Guide.replace_places(entry, [])

    assert [%{item: item, live?: false, bookmark: b}] = Bookmarks.list(reader.id)
    assert item.name == "Tsuruya"
    assert item.lat == 36.25
    assert item.id == -b.id

    assert {:ok, :removed} = Bookmarks.remove(reader.id, b.id)
    assert Bookmarks.list(reader.id) == []
  end

  test "a poet who turns private keeps its name in the list, not its position",
       %{reader: reader, poet: poet, place: place} do
    {:ok, :saved} = Bookmarks.toggle(reader.id, "place", place.id)
    {:ok, _} = Poets.update_poet(poet, %{is_public: false})

    assert [%{item: item}] = Bookmarks.list(reader.id)
    assert item.name == "Tsuruya"
    assert item.lat == nil
  end
end
