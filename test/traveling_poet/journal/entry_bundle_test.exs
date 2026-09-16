defmodule TravelingPoet.Journal.EntryBundleTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Guide, Journal, Poets}
  alias TravelingPoet.Journal.EntryBundle

  defp setup_poet do
    user = user_fixture()
    poet = poet_fixture(user)
    {:ok, _} = Poets.move_to(poet, %{lat: 38.72, lng: -9.13, place_name: "Lisbon, Portugal"})
    {user, poet}
  end

  test "nil is an empty bundle, so pages read its fields without a nil check" do
    assert %EntryBundle{entry: nil, media: %{}, spreads: [], places: [], stay_id: nil} =
             EntryBundle.load(nil)
  end

  test "one entry: section media, the stray drawing, the spot woven in, the day's places, the stay" do
    {_user, poet} = setup_poet()
    entry = published_entry_fixture(poet)

    drawing = media_fixture(poet, %{journal_entry_id: entry.id})
    stray = media_fixture(poet, %{journal_entry_id: entry.id})
    spot = media_fixture(poet, %{journal_entry_id: entry.id, kind: "spot", alt_text: "a cat"})
    place_drawing = media_fixture(poet, %{})

    {:ok, _} =
      Journal.replace_sections(entry, [
        %{kind: "illustration", media_id: drawing.id},
        %{kind: "description", body: "First paragraph.\n\nSecond paragraph.\n\nThird."},
        %{kind: "poem", title: "Tram 28", body: "yellow\nclatter"}
      ])

    place = place_fixture(poet, entry, %{name: "Tasca do Chico", media_id: place_drawing.id})
    entry = Journal.preload_entry(Journal.get_entry!(entry.id))

    bundle = EntryBundle.load(entry)

    assert Map.keys(bundle.media) == [drawing.id]
    assert Enum.map(bundle.extra_media, & &1.id) == [stray.id]
    assert Map.keys(bundle.spot_media) == [spot.id]

    # the unclaimed spot is on the page, but only on the page
    description = Enum.find(bundle.entry.sections, &(&1.kind == "description"))
    assert description.body =~ "](/media/#{spot.id})"

    refute Journal.preload_entry(Journal.get_entry!(entry.id)).sections
           |> Enum.any?(&((&1.body || "") =~ "/media/"))

    assert Enum.map(bundle.places, & &1.id) == [place.id]
    assert Map.keys(bundle.place_media) == [place_drawing.id]
    assert bundle.finds == [] and bundle.find_media == %{}

    assert bundle.stay_id == Poets.current_path_point(poet.id).id
    assert [%{key: "today"}, %{key: "places", right: [{:place, _}]}] = bundle.spreads
  end

  test "a place's drawing never shows up as a stray taped photo" do
    {_user, poet} = setup_poet()
    entry = published_entry_fixture(poet)
    place_drawing = media_fixture(poet, %{journal_entry_id: entry.id})
    place_fixture(poet, entry, %{media_id: place_drawing.id})

    bundle = EntryBundle.load(Journal.preload_entry(Journal.get_entry!(entry.id)))
    assert bundle.extra_media == []
    assert Map.keys(bundle.place_media) == [place_drawing.id]
  end

  test "an excursion day carries finds, not places, and the Finds spread" do
    {_user, poet} = setup_poet()
    topic = topic_fixture(poet)
    entry = published_entry_fixture(poet)
    excursion_fixture(poet, topic, entry)
    find = find_fixture(poet, entry)
    place_fixture(poet, entry)

    bundle = EntryBundle.load(Journal.get_entry!(entry.id))

    assert Enum.map(bundle.finds, & &1.id) == [find.id]
    assert bundle.places == []
    assert [%{key: "today"}, %{key: "finds"}] = bundle.spreads
  end

  test "load_many keeps the order given and files each day under its own stay" do
    user = user_fixture()
    poet = poet_fixture(user)
    {:ok, _} = Poets.move_to(poet, %{lat: 34.03, lng: -5.0, place_name: "Fez, Morocco"})
    fez = Poets.current_path_point(poet.id)

    fez_day =
      published_entry_fixture(poet, %{
        entry_date: Date.add(Date.utc_today(), -1),
        place_name: "Fez, Morocco"
      })

    {:ok, _} = Poets.move_to(poet, %{lat: 38.25, lng: -85.75, place_name: "Louisville, USA"})
    louisville = Poets.current_path_point(poet.id)
    travel_day = published_entry_fixture(poet, %{place_name: "Louisville, USA"})

    entries = Journal.list_entries(poet.id, status: "published", order: :asc)
    assert Enum.map(entries, & &1.id) == [fez_day.id, travel_day.id]

    [first, second] = EntryBundle.load_many(entries)
    assert first.entry.id == fez_day.id
    assert second.entry.id == travel_day.id

    # the travel day belongs to the place moved TO, exactly as the guide files it
    assert second.stay_id == louisville.id
    assert second.stay_id == Guide.path_point_for(travel_day)

    # Fez was yesterday: covered by the Fez stay alone
    assert first.stay_id == fez.id
  end

  test "list_entries reads the whole journey when asked, oldest first" do
    {_user, poet} = setup_poet()

    for i <- 0..64 do
      published_entry_fixture(poet, %{entry_date: Date.add(~D[2026-01-01], i)})
    end

    assert length(Journal.list_entries(poet.id, status: "published")) == 60

    all = Journal.list_entries(poet.id, status: "published", limit: :all, order: :asc)
    assert length(all) == 65
    assert hd(all).entry_date == ~D[2026-01-01]
    assert List.last(all).entry_date == ~D[2026-03-06]
  end
end
