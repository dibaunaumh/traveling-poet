defmodule TravelingPoet.PlaceExtractorTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.Guide.Extractor

  # Keys are nil in :test, so the extractor degrades instead of reaching the
  # network -- same convention as the illustrations endpoint asserting 503.
  test "extraction is a no-op without a key, and says which" do
    refute Extractor.configured?()

    poet = poet_fixture(user_fixture())
    entry = published_entry_fixture(poet)
    sections = [%{kind: "description", body: "We ate at Tasca do Chico."}]

    assert Extractor.extract(entry, sections) == {:error, :not_configured}
  end

  test "an entry with no prose never reaches the model" do
    poet = poet_fixture(user_fixture())
    entry = published_entry_fixture(poet)

    # Only a poem: no prose kinds, so there is nothing to extract from.
    assert Extractor.extract(entry, [%{kind: "poem", body: "a small blue bird"}]) == {:ok, []}
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
