defmodule TravelingPoet.GuideTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Guide, Poets}
  alias TravelingPoet.Guide.Place

  defp setup_poet do
    user = user_fixture()
    poet = poet_fixture(user)
    {user, poet}
  end

  defp attrs(name, extra \\ %{}) do
    Map.merge(%{"name" => name, "category" => "restaurant"}, extra)
  end

  describe "replace_places/2" do
    test "is idempotent by entry — re-sending a day's list replaces, never duplicates" do
      {_user, poet} = setup_poet()
      entry = published_entry_fixture(poet)

      {:ok, _} = Guide.replace_places(entry, [attrs("Tasca do Chico"), attrs("Time Out Market")])
      {:ok, _} = Guide.replace_places(entry, [attrs("Tasca do Chico"), attrs("Time Out Market")])

      names = Guide.list_places_for_entry(entry.id) |> Enum.map(& &1.name)
      assert names == ["Tasca do Chico", "Time Out Market"]
    end

    # A geocode costs one request against a 1 req/s app-wide budget, and a
    # drawing costs one of six daily image slots. SKILL.md has the poet
    # re-sending its list within the same run, so a naive delete-and-reinsert
    # would spend both twice for no gain.
    test "a re-put keeps the coordinates and the drawing a place already earned" do
      {_user, poet} = setup_poet()
      entry = published_entry_fixture(poet)

      {:ok, _} = Guide.replace_places(entry, [attrs("Tasca do Chico")])
      [place] = Guide.list_places_for_entry(entry.id)
      media = media_fixture(poet)
      {:ok, _} = Guide.update_geocode(place, %{lat: 38.71, lng: -9.14})
      {:ok, _} = Guide.attach_media(Repo.get!(Place, place.id), media.id)

      {:ok, _} = Guide.replace_places(entry, [attrs("Tasca do Chico", %{"blurb" => "reworded"})])

      [kept] = Guide.list_places_for_entry(entry.id)
      assert kept.lat == 38.71
      assert kept.lng == -9.14
      assert kept.geocode_status == "ok"
      assert kept.media_id == media.id
      assert kept.blurb == "reworded"
    end

    test "a renamed place starts over rather than inheriting another's pin" do
      {_user, poet} = setup_poet()
      entry = published_entry_fixture(poet)

      {:ok, _} = Guide.replace_places(entry, [attrs("Tasca do Chico")])
      [place] = Guide.list_places_for_entry(entry.id)
      {:ok, _} = Guide.update_geocode(place, %{lat: 38.71, lng: -9.14})

      {:ok, _} = Guide.replace_places(entry, [attrs("Cervejaria Ramiro")])

      [fresh] = Guide.list_places_for_entry(entry.id)
      assert fresh.lat == nil
      assert fresh.geocode_status == "pending"
    end

    test "an unknown category buckets into sights instead of failing the write" do
      {_user, poet} = setup_poet()
      entry = published_entry_fixture(poet)

      {:ok, _} = Guide.replace_places(entry, [attrs("Somewhere", %{"category" => "speakeasy"})])

      [place] = Guide.list_places_for_entry(entry.id)
      assert place.category == "attraction"
      assert Place.group_for(place.category) == "sights"
    end

    test "places land in the stay that covers the entry's date" do
      {_user, poet} = setup_poet()

      {:ok, _} =
        Poets.move_to(poet, %{lat: 38.72, lng: -9.13, place_name: "Lisbon, Portugal"})

      entry = published_entry_fixture(poet)
      {:ok, _} = Guide.replace_places(entry, [attrs("Tasca do Chico")])

      [place] = Guide.list_places_for_entry(entry.id)
      stay = Poets.current_path_point(poet.id)
      assert place.path_point_id == stay.id
    end

    # The backfill's case: entries written before the poet's path was being
    # tracked predate every arrived_at. Without a fallback they would all land
    # outside every stay, and the guide would lose its city grouping for
    # exactly the trips the backfill exists to rescue.
    test "an entry older than every stay still lands in the earliest one" do
      {_user, poet} = setup_poet()

      {:ok, _} =
        Poets.move_to(poet, %{lat: 38.72, lng: -9.13, place_name: "Lisbon, Portugal"})

      old_entry = published_entry_fixture(poet, %{entry_date: Date.add(Date.utc_today(), -30)})
      {:ok, _} = Guide.replace_places(old_entry, [attrs("Tasca do Chico")])

      [place] = Guide.list_places_for_entry(old_entry.id)
      assert place.path_point_id == Poets.current_path_point(poet.id).id
      assert Guide.list_stays(poet.id) != []
    end

    # covers?/2 compares dates, not timestamps, so on a day the poet travelled
    # BOTH stays cover the date. Taking the earlier one put a day of Louisville
    # places under a "Fez, Morocco" tab on poet E, whose onboarding left a
    # five-minute Fez path point before it moved -- and the map dutifully
    # showed Louisville pins there.
    test "on a travel day the entry belongs to the place the poet moved TO" do
      {_user, poet} = setup_poet()

      {:ok, _} = Poets.move_to(poet, %{lat: 34.03, lng: -5.0, place_name: "Fez, Morocco"})
      {:ok, _} = Poets.move_to(poet, %{lat: 38.25, lng: -85.75, place_name: "Louisville, USA"})

      entry = published_entry_fixture(poet, %{place_name: "Louisville, USA"})
      {:ok, _} = Guide.replace_places(entry, [attrs("Louisville Slugger Museum")])

      [place] = Guide.list_places_for_entry(entry.id)
      arrived = Poets.current_path_point(poet.id)

      assert place.path_point_id == arrived.id
      assert arrived.place_name == "Louisville, USA"
    end

    test "reassign_stays repairs places already filed under the wrong stay" do
      {_user, poet} = setup_poet()

      {:ok, _} = Poets.move_to(poet, %{lat: 34.03, lng: -5.0, place_name: "Fez, Morocco"})
      fez = Poets.current_path_point(poet.id)
      {:ok, _} = Poets.move_to(poet, %{lat: 38.25, lng: -85.75, place_name: "Louisville, USA"})

      entry = published_entry_fixture(poet, %{place_name: "Louisville, USA"})
      {:ok, [place]} = Guide.replace_places(entry, [attrs("Louisville Slugger Museum")])

      # Force the old, wrong attribution back on.
      {:ok, _} = place |> Place.changeset(%{path_point_id: fez.id}) |> Repo.update()

      assert Guide.reassign_stays(poet.id) == 1

      [repaired] = Guide.list_places_for_entry(entry.id)
      assert repaired.path_point_id == Poets.current_path_point(poet.id).id
      assert Guide.reassign_stays(poet.id) == 0
    end

    test "a poet with no path points at all still saves its places" do
      {_user, poet} = setup_poet()
      entry = published_entry_fixture(poet)

      {:ok, _} = Guide.replace_places(entry, [attrs("Tasca do Chico")])

      [place] = Guide.list_places_for_entry(entry.id)
      assert place.path_point_id == nil
      assert length(Guide.list_places(poet.id)) == 1
    end
  end

  describe "list_places/2" do
    # A draft entry is prose the poet has not shown anyone yet. Its places must
    # not be reachable either.
    test "published_only is the default — a draft entry's places never reach a reader" do
      {_user, poet} = setup_poet()
      draft = entry_fixture(poet)
      {:ok, _} = Guide.replace_places(draft, [attrs("Secret Bar")])

      assert Guide.list_places(poet.id) == []
      assert [%Place{name: "Secret Bar"}] = Guide.list_places(poet.id, published_only: false)
    end

    test "filters narrow to the right group" do
      {_user, poet} = setup_poet()
      entry = published_entry_fixture(poet)

      {:ok, _} =
        Guide.replace_places(entry, [
          attrs("Ramiro", %{"category" => "restaurant"}),
          attrs("Fado ao Castelo", %{"category" => "event"}),
          attrs("Miradouro", %{"category" => "viewpoint"})
        ])

      assert Guide.list_places(poet.id, group: "food") |> Enum.map(& &1.name) == ["Ramiro"]

      assert Guide.list_places(poet.id, group: "events") |> Enum.map(& &1.name) == [
               "Fado ao Castelo"
             ]

      assert Guide.list_places(poet.id, group: "sights") |> Enum.map(& &1.name) == ["Miradouro"]
      assert length(Guide.list_places(poet.id, group: "all")) == 3
    end

    # A place the geocoder could not find is still a real recommendation. It
    # loses its pin, not its place in the guide.
    test "a place that never geocoded still lists, and is simply absent from the map" do
      {_user, poet} = setup_poet()
      entry = published_entry_fixture(poet)
      {:ok, _} = Guide.replace_places(entry, [attrs("Nameless viewpoint")])
      [place] = Guide.list_places_for_entry(entry.id)
      {:ok, _} = Guide.mark_geocode_failed(place)

      places = Guide.list_places(poet.id)
      assert length(places) == 1
      assert Guide.map_payload(places, "Wren") == []
      assert Guide.unmapped_count(places) == 1
    end
  end

  describe "group_by_day/1" do
    # arrived_at on the poet record is reset by every move_to/2, so it cannot
    # number a trip. Days are counted from the dates that actually produced
    # places, which also means a skipped day leaves no hole.
    test "days number consecutively even when the poet skipped a day" do
      {_user, poet} = setup_poet()
      today = Date.utc_today()

      for {offset, name} <- [{-4, "First"}, {-2, "Third"}] do
        entry = published_entry_fixture(poet, %{entry_date: Date.add(today, offset)})
        {:ok, _} = Guide.replace_places(entry, [attrs(name)])
      end

      days = poet.id |> Guide.list_places() |> Guide.group_by_day()

      assert Enum.map(days, & &1.day) == [1, 2]
      assert days |> Enum.flat_map(& &1.places) |> Enum.map(& &1.name) == ["First", "Third"]
    end
  end

  describe "counts_by_group/1" do
    # If a new category is ever added without touching group_for/1, it must
    # still be counted somewhere rather than silently vanishing from every chip.
    test "every place lands in exactly one chip, and all sums to the total" do
      {_user, poet} = setup_poet()
      entry = published_entry_fixture(poet)

      places =
        for {category, i} <- Enum.with_index(Place.categories()) do
          place_fixture(poet, entry, %{name: "P#{i}", category: category, position: i})
        end

      counts = Guide.counts_by_group(places)

      assert counts["all"] == length(Place.categories())
      assert counts["food"] + counts["sights"] + counts["events"] == counts["all"]
    end
  end
end
