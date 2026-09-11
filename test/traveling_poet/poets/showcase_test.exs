defmodule TravelingPoet.Poets.ShowcaseTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Journal, Poets}
  alias TravelingPoet.Poets.Showcase

  defp publish(poet, date, attrs) do
    {:ok, entry} = Journal.upsert_entry(poet.id, date, Map.merge(%{title: "Day"}, attrs))
    {:ok, _} = Journal.replace_sections(entry, [%{kind: "description", body: "a day"}])
    {:ok, entry} = Journal.publish_entry(entry)
    entry
  end

  test "a public poet's journey, drawings and numbers; a private one is a blurred dot" do
    nam = poet_fixture(user_fixture(), %{name: "Nam", is_public: true, status: "active"})

    {:ok, _} =
      Poets.move_to(nam, %{lat: 38.72, lng: -9.14, place_name: "Lisbon", country_code: "PT"})

    {:ok, _} =
      Poets.move_to(nam, %{lat: 40.4, lng: -3.7, place_name: "Madrid", country_code: "ES"})

    nam = Poets.get_poet(nam.id)

    e1 = publish(nam, ~D[2026-09-01], %{place_name: "Lisbon", lat: 38.72, lng: -9.14})
    e2 = publish(nam, ~D[2026-09-03], %{place_name: "Madrid", lat: 40.4, lng: -3.7})
    _draft = Journal.upsert_entry(nam.id, ~D[2026-09-04], %{title: "Draft", lat: 1.0, lng: 1.0})

    drawing = media_fixture(nam, %{journal_entry_id: e2.id, alt_text: "Gran Via in rain"})
    media_fixture(nam, %{journal_entry_id: e2.id, alt_text: "a second sketch"})
    place_fixture(nam, e1)

    poet_fixture(user_fixture(), %{
      name: "Hidden Hilda",
      is_public: false,
      status: "active",
      current_lat: 13.7524938,
      current_lng: 100.4935089,
      current_place_name: "Bangkok, Thailand"
    })

    mine = poet_fixture(user_fixture(), %{name: "Ada", current_place_name: "Porto, Portugal"})

    showcase = Showcase.build(mine, ~D[2026-09-05])

    assert showcase.me == %{lat: 38.7223, lng: -9.1393, name: "Porto, Portugal", poet: "Ada"}
    assert showcase.anonymous == [%{lat: 13.8, lng: 100.5}]

    assert [poet] = showcase.poets
    assert poet.slug == nam.slug
    assert Enum.map(poet.path, & &1.name) == ["Lisbon", "Madrid"]
    assert poet.stats == %{days: 5, entries: 2, places: 1, countries: 2, drawings: 2}
    assert poet.latest_url == "/p/#{nam.slug}/2026-09-03"

    assert [lisbon, madrid] = poet.stops
    assert lisbon.media == nil
    assert madrid.place == "Madrid"
    assert madrid.media.id == drawing.id

    assert showcase.totals == %{poets: 2, entries: 2, places: 1, countries: 2, drawings: 2}

    # The private poet leaks nothing but a rounded dot.
    dump = inspect(showcase, limit: :infinity)
    refute dump =~ "Hilda"
    refute dump =~ "Bangkok"
    refute dump =~ "13.7524938"

    # The hook's payload carries no structs.
    payload = Showcase.tour_payload(showcase)
    assert [%{stops: [_, %{media: media_id}]}] = payload.poets
    assert media_id == drawing.id
    assert {:ok, _} = Jason.encode(payload)
  end

  test "an empty fleet still describes where the reader's poet starts" do
    mine = poet_fixture(user_fixture(), %{name: "Ada"})
    showcase = Showcase.build(mine)

    assert showcase.poets == []
    assert showcase.anonymous == []
    assert showcase.totals == %{poets: 0, entries: 0, places: 0, countries: 0, drawings: 0}
    assert showcase.me.poet == "Ada"
    assert {:ok, _} = Jason.encode(Showcase.tour_payload(showcase))
  end

  test "the reader's own poet never gets a card of its own" do
    mine = poet_fixture(user_fixture(), %{name: "Ada", is_public: true, status: "active"})
    assert Showcase.build(mine).poets == []
  end
end
