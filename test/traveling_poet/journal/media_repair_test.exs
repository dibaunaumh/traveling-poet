defmodule TravelingPoet.Journal.MediaRepairTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.Journal
  alias TravelingPoet.Journal.{Media, MediaRepair}

  setup do
    poet = poet_fixture(user_fixture())
    %{poet: poet}
  end

  test "links each unlinked drawing to the page that carries it, on commit only", %{poet: poet} do
    # Nam's page of 2026-10-20: the main drawing pasted into the illustration
    # section as markdown, two spots in the prose, all three drawn before
    # the entry row existed.
    entry = entry_fixture(poet, %{entry_date: Date.utc_today()})
    main = media_fixture(poet)
    spot = media_fixture(poet, %{kind: "spot"})
    forgotten = media_fixture(poet, %{kind: "spot"})
    place_drawing = media_fixture(poet)
    place_fixture(poet, entry, %{media_id: place_drawing.id})

    # Insert the sections directly: replace_sections/2 now links on write.
    for {kind, body, pos} <- [
          {"description", "![wool](/media/#{spot.id})\n\nThe wool sellers.", 0},
          {"illustration", "![market](/media/#{main.id})", 1}
        ] do
      %TravelingPoet.Journal.Section{}
      |> TravelingPoet.Journal.Section.changeset(%{
        journal_entry_id: entry.id,
        kind: kind,
        body: body,
        position: pos
      })
      |> Repo.insert!()
    end

    dry = MediaRepair.run()
    assert dry.linked == [{main.id, entry.id}, {spot.id, entry.id}]
    assert dry.unreferenced == [forgotten.id]
    refute dry.committed
    assert is_nil(Repo.get!(Media, main.id).journal_entry_id)

    done = MediaRepair.run(commit: true)
    assert done.linked == dry.linked
    assert done.committed

    assert Enum.map(Journal.spot_media(entry), & &1.id) == [spot.id]
    assert Enum.map(Journal.unattached_illustrations(entry, []), & &1.id) == [main.id]
    assert is_nil(Repo.get!(Media, forgotten.id).journal_entry_id)
    assert is_nil(Repo.get!(Media, place_drawing.id).journal_entry_id)

    # idempotent
    assert MediaRepair.run(commit: true).linked == []
  end
end
