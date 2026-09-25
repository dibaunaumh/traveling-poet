defmodule TravelingPoet.ReadingTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, Journal, Reading}
  alias TravelingPoet.Journal.Paragraphs

  @para "Lisbon hits you first by smell: salt, diesel, baking bread, and something floral."
  @poem "a short line of verse\nthat is long enough to count as prose"

  setup do
    user = user_fixture()
    poet = poet_fixture(user)
    entry = entry_fixture(poet, %{entry_date: ~D[2026-09-25]})

    {:ok, _} =
      Journal.replace_sections(entry, [
        %{kind: "description", body: @para},
        %{kind: "poem", body: @poem}
      ])

    %{user: user, poet: poet, entry: entry, key: Paragraphs.key(@para)}
  end

  test "keeps time on the entry's own paragraphs, adding up within a day",
       %{user: user, entry: entry, key: key} do
    assert Reading.record(user, entry, %{key => 4_000}, ~D[2026-09-25]) == 1
    assert Reading.record(user, entry, %{key => 3_000}, ~D[2026-09-25]) == 1
    Reading.record(user, entry, %{key => 1_000}, ~D[2026-09-26])

    [next_day, day] = Reading.list(user)
    assert {day.read_on, day.ms, day.chars} == {~D[2026-09-25], 7_000, String.length(@para)}
    assert {next_day.read_on, next_day.ms} == {~D[2026-09-26], 1_000}
  end

  test "ignores keys that are not prose paragraphs of the entry, and nonsense times",
       %{user: user, entry: entry, key: key} do
    poem_key = Paragraphs.key(@poem)

    assert Reading.record(user, entry, %{
             "0123456789abcdef" => 5_000,
             poem_key => 5_000,
             key => "lots"
           }) == 0

    assert Reading.list(user) == []
  end

  test "caps one report per paragraph", %{user: user, entry: entry, key: key} do
    Reading.record(user, entry, %{key => 3_600_000})
    assert [%{ms: ms}] = Reading.list(user)
    assert ms == Reading.max_ms_per_report()
  end

  test "records nothing for someone else's journal", %{entry: entry, key: key} do
    stranger = user_fixture()
    assert Reading.record(stranger, entry, %{key => 5_000}) == 0
    assert Reading.list(stranger) == []
  end

  test "records nothing with the switch off, and forget/1 clears what was kept",
       %{user: user, entry: entry, key: key} do
    Reading.record(user, entry, %{key => 5_000})
    assert Reading.forget(user) == 1

    {:ok, off} = Accounts.update_user(user, %{reading_signals: false})
    assert Reading.record(off, entry, %{key => 5_000}) == 0
    assert Reading.list(off) == []
  end
end
