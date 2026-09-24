defmodule TravelingPoet.PlaceTopicsTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.Guide
  alias TravelingPoet.Guide.{Place, PlaceClassifier, PlaceTopics, TopicTagging}
  alias TravelingPoet.Repo

  @contemporary "art/modern-and-contemporary-art/contemporary-art"
  @jazz "music-and-performance/music/jazz"
  @weaving "crafts-and-design/textiles/weaving-and-silk"

  # The reply OpenRouter would give, as the classifier sees it.
  defp stub_reply(verdicts) do
    Req.Test.stub(TravelingPoet.PlaceClassifier, fn conn ->
      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"content" => Jason.encode!(%{"places" => verdicts})}}]
      })
    end)
  end

  describe "the tree" do
    test "is the approved one: 12, 53 and 157 topics, every path three levels" do
      tree = PlaceTopics.tree()
      assert length(tree) == 12
      assert tree |> Enum.flat_map(& &1["children"]) |> length() == 53
      assert length(PlaceTopics.paths()) == 157

      assert PlaceTopics.valid?(@contemporary)
      refute PlaceTopics.valid?("art/modern-and-contemporary-art")
      refute PlaceTopics.valid?("art/made-up/topic")
      assert PlaceTopics.names(@weaving) == ["Crafts & design", "Textiles", "Weaving & silk"]
    end

    test "place types come from a fixed list" do
      assert PlaceTopics.normalize_type(" Museum ") == "museum"
      assert PlaceTopics.normalize_type("spaceship") == "other"
      assert PlaceTopics.normalize_type(nil) == "other"
    end
  end

  describe "PlaceClassifier.parse_response/2" do
    test "keeps topics from the tree, at most two, for the ids asked" do
      raw =
        Jason.encode!(%{
          "places" => [
            %{
              "id" => 1,
              "topics" => [@jazz, "food-and-drink/made/up", @contemporary, @weaving],
              "type" => "restaurant"
            },
            %{"id" => "2", "topics" => [], "type" => "museum"},
            %{"id" => 99, "topics" => [@jazz], "type" => "venue"}
          ]
        })

      assert %{
               1 => %{topic: @jazz, second_topic: @contemporary, place_type: "restaurant"},
               2 => %{topic: nil, second_topic: nil, place_type: nil}
             } =
               verdicts = PlaceClassifier.parse_response("```json\n" <> raw <> "\n```", [1, 2, 3])

      # 99 was not asked about; 3 was not answered and stays for the next run
      assert Map.keys(verdicts) |> Enum.sort() == [1, 2]
    end

    test "an answer naming only topics outside the tree is no answer, not 'untaggable'" do
      raw =
        Jason.encode!(%{
          "places" => [%{"id" => 1, "topics" => ["food-and-drink/cuisines/klingon"]}]
        })

      assert PlaceClassifier.parse_response(raw, [1]) == %{}
    end

    test "garbage is no verdicts, never a crash" do
      assert PlaceClassifier.parse_response("not json", [1]) == %{}
      assert PlaceClassifier.parse_response(nil, [1]) == %{}
    end
  end

  test "without a key nothing is classified" do
    assert PlaceClassifier.classify([%{id: 1, name: "X", category: "shop"}]) ==
             {:error, :not_configured}
  end

  describe "tagging" do
    setup do
      poet = poet_fixture(user_fixture())
      entry = published_entry_fixture(poet, %{place_name: "Kyoto"})

      {:ok, [tex, club]} =
        Guide.replace_places(entry, [
          %{"name" => "Nishijin Textile Center", "category" => "attraction"},
          %{"name" => "SOUTH Restaurant & Jazz Club", "category" => "restaurant"}
        ])

      %{entry: entry, tex: tex, club: club}
    end

    test "an entry's places get their topics and a type", %{entry: entry, tex: tex, club: club} do
      stub_reply([
        %{"id" => tex.id, "topics" => [@weaving], "type" => "museum"},
        %{
          "id" => club.id,
          "topics" => [@jazz, "food-and-drink/cuisines/american-regional"],
          "type" => "restaurant"
        }
      ])

      assert TopicTagging.tag_entry(entry.id, api_key: "k") == 2

      tex = Repo.get!(Place, tex.id)
      assert tex.topic == @weaving
      assert tex.second_topic == nil
      assert tex.place_type == "museum"
      assert tex.topics_classified_at

      assert Repo.get!(Place, club.id).second_topic == "food-and-drink/cuisines/american-regional"

      # classified places are not sent again
      assert TopicTagging.tag_entry(entry.id, api_key: "k") == 0
    end

    test "a place the model skipped stays unclassified for the next run", %{
      entry: entry,
      tex: tex,
      club: club
    } do
      stub_reply([%{"id" => tex.id, "topics" => [@weaving], "type" => "museum"}])

      assert TopicTagging.tag_entry(entry.id, api_key: "k") == 1
      assert Repo.get!(Place, club.id).topics_classified_at == nil
    end

    test "a failed call writes nothing", %{entry: entry, tex: tex} do
      Req.Test.stub(TravelingPoet.PlaceClassifier, &Plug.Conn.send_resp(&1, 500, "down"))

      assert TopicTagging.tag_entry(entry.id, api_key: "k") == 0
      assert Repo.get!(Place, tex.id).topics_classified_at == nil
    end

    test "a poet re-sending the entry's places keeps their topics", %{entry: entry, tex: tex} do
      stub_reply([%{"id" => tex.id, "topics" => [@weaving], "type" => "museum"}])
      TopicTagging.tag_entry(entry.id, api_key: "k")

      {:ok, saved} =
        Guide.replace_places(entry, [
          # a poet cannot set topics itself
          %{"name" => "Nishijin Textile Center", "category" => "attraction", "topic" => @jazz},
          %{"name" => "A new place", "category" => "cafe", "topic" => @jazz}
        ])

      [kept, fresh] = Enum.sort_by(saved, & &1.position)
      assert kept.topic == @weaving
      assert kept.place_type == "museum"
      assert kept.topics_classified_at
      assert fresh.topic == nil
      assert fresh.topics_classified_at == nil
    end

    test "the async hook is off unless switched on", %{entry: entry} do
      assert TopicTagging.tag_entry_async(entry.id) == :disabled
    end

    test "the backfill is a dry run unless told to commit", %{tex: tex, club: club} do
      stub_reply([
        %{"id" => tex.id, "topics" => [@weaving], "type" => "museum"},
        %{"id" => club.id, "topics" => [], "type" => "other"}
      ])

      report = TopicTagging.backfill(api_key: "k")
      assert report.committed == false
      assert report.places == 2
      assert report.classified == 2
      assert report.untagged == ["SOUTH Restaurant & Jazz Club"]
      assert report.by_top == %{"Crafts & design" => 1}
      assert report.samples[@weaving] == ["Nishijin Textile Center"]
      assert Repo.get!(Place, tex.id).topics_classified_at == nil

      report = TopicTagging.backfill(api_key: "k", commit: true)
      assert report.committed
      assert Repo.get!(Place, tex.id).topic == @weaving
      # untaggable, but classified: it will not be paid for again
      assert Repo.get!(Place, club.id).topics_classified_at
      assert TopicTagging.backfill(api_key: "k").places == 0
    end
  end
end
