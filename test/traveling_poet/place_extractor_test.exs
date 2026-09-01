defmodule TravelingPoet.PlaceExtractorTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Guide, Journal}
  alias TravelingPoet.Guide.{Backfill, Extractor}

  # Keys are nil in :test, so the extractor degrades instead of reaching the
  # network -- same convention as the illustrations endpoint asserting 503.
  test "extraction is a no-op without a key, and says which" do
    refute Extractor.configured?()

    poet = poet_fixture(user_fixture())
    entry = published_entry_fixture(poet)
    sections = [%{kind: "description", body: "We ate at Tasca do Chico."}]

    assert Extractor.extract(entry, sections) == {:error, :not_configured}
  end

  # A kindness section carries a charity or a food bank, and the extractor has
  # no category that fits, so it labelled them "attraction" -- the 2026-09-01
  # dry run turned a food bank into a tourist attraction. The opportunity
  # already has its own place in the entry with an official link.
  test "a kindness section is not mined for places" do
    poet = poet_fixture(user_fixture())
    entry = published_entry_fixture(poet)

    sections = [%{kind: "kindness", body: "Banco Alimentar Contra a Fome takes donations."}]

    # No prose kinds present, so it short-circuits before any model call --
    # which is only true if kindness is excluded.
    assert Extractor.extract(entry, sections) == {:ok, []}
  end

  test "description, art_culture and products are still mined" do
    poet = poet_fixture(user_fixture())
    entry = published_entry_fixture(poet)

    for kind <- ~w(description art_culture products) do
      assert {:error, :not_configured} =
               Extractor.extract(entry, [%{kind: kind, body: "We ate at Tasca do Chico."}]),
             "#{kind} should have reached the model"
    end
  end

  test "an entry with no prose never reaches the model" do
    poet = poet_fixture(user_fixture())
    entry = published_entry_fixture(poet)

    # Only a poem: no prose kinds, so there is nothing to extract from.
    assert Extractor.extract(entry, [%{kind: "poem", body: "a small blue bird"}]) == {:ok, []}
  end

  describe "Backfill.run/1" do
    # The Mix task cannot run where the backfill is actually needed:
    # production is a release and a release has no Mix. The logic lives in a
    # plain module so `bin/traveling_poet rpc` can call it.
    test "is callable without Mix and reports per-entry outcomes" do
      poet = poet_fixture(user_fixture())
      published_entry_fixture(poet)

      %{entries: entries, totals: totals} = Backfill.run(poet_id: poet.id)

      assert [%{poet_id: _, date: _, city: _, status: _}] = entries
      assert totals.entries == 1
      assert totals.committed == false
    end

    test "a dry run writes nothing" do
      poet = poet_fixture(user_fixture())
      entry = published_entry_fixture(poet)

      Backfill.run(poet_id: poet.id)

      assert Guide.list_places_for_entry(entry.id) == []
    end

    test "an entry that already has places is skipped unless forced" do
      poet = poet_fixture(user_fixture())
      entry = published_entry_fixture(poet)
      {:ok, _} = Guide.replace_places(entry, [%{"name" => "Existing", "category" => "cafe"}])

      %{entries: [result]} = Backfill.run(poet_id: poet.id)

      assert result.status == :skipped_has_places
    end

    # Keys are nil in :test, so extraction degrades rather than reaching the
    # network -- and one bad entry must never take the rest of the run down.
    test "an unextractable entry is recorded as failed, not raised" do
      poet = poet_fixture(user_fixture())
      entry = published_entry_fixture(poet)
      {:ok, _} = Journal.replace_sections(entry, [%{kind: "description", body: "Some prose."}])

      %{entries: [result], totals: totals} = Backfill.run(poet_id: poet.id)

      assert {:failed, :not_configured} = result.status
      assert totals.failed == 1
    end

    # Same cap the agent endpoint applies. An entry that mentions twenty places
    # is a wall, not a guide, and the two write paths must not disagree.
    test "no more than eight places are taken from a single entry" do
      assert TravelingPoet.Guide.Backfill.max_places_per_entry() == 8
    end

    test "the limit bounds how many entries a run can touch" do
      poet = poet_fixture(user_fixture())

      for offset <- 1..4 do
        published_entry_fixture(poet, %{entry_date: Date.add(Date.utc_today(), -offset)})
      end

      assert %{totals: %{entries: 2}} = Backfill.run(poet_id: poet.id, limit: 2)
    end
  end

  # This, not the HTTP call, is where the risk lives: the fleet models fumble
  # structured output often enough that a malformed response must never break
  # a run.
  describe "parse_response/1" do
    test "accepts the documented object shape" do
      assert [%{"name" => "Ramiro"}] =
               Extractor.parse_response(~s({"places":[{"name":"Ramiro"}]}))
    end

    test "accepts a bare array" do
      assert [%{"name" => "Ramiro"}] = Extractor.parse_response(~s([{"name":"Ramiro"}]))
    end

    test "survives markdown fences" do
      assert [%{"name" => "Ramiro"}] =
               Extractor.parse_response("```json\n{\"places\":[{\"name\":\"Ramiro\"}]}\n```")
    end

    test "event dates survive parsing" do
      assert [%{"starts_on" => "2026-08-21", "ends_on" => "2026-09-27"}] =
               Extractor.parse_response(
                 ~s({"places":[{"name":"Vermeer","starts_on":"2026-08-21","ends_on":"2026-09-27"}]})
               )
    end

    test "garbage yields an empty list rather than raising" do
      assert Extractor.parse_response("I'm sorry, I can't help with that.") == []
      assert Extractor.parse_response("{not json") == []
      assert Extractor.parse_response(nil) == []
      assert Extractor.parse_response(~s({"places": "Ramiro"})) == []
    end

    test "non-map entries in the list are dropped" do
      assert Extractor.parse_response(~s({"places":["Ramiro",{"name":"Real"}]})) == [
               %{"name" => "Real"}
             ]
    end
  end
end
