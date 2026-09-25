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
    test "is the approved one: 12, 54 and 180 topics, every path three levels" do
      tree = PlaceTopics.tree()
      assert length(tree) == 12
      assert tree |> Enum.flat_map(& &1["children"]) |> length() == 54
      assert length(PlaceTopics.paths()) == 180

      assert PlaceTopics.valid?(@contemporary)
      refute PlaceTopics.valid?("art/modern-and-contemporary-art")
      refute PlaceTopics.valid?("art/made-up/topic")
      assert PlaceTopics.names(@weaving) == ["Crafts & design", "Textiles", "Weaving & silk"]
    end

    test "v3 adds works and fields of thought without moving a single v2 path" do
      # places already store v2 paths: renaming Film to "Film & TV" kept its slug
      assert PlaceTopics.valid?("music-and-performance/film/cinemas-and-film-festivals")

      assert PlaceTopics.names("music-and-performance/film/tv-and-series") ==
               ["Music & performance", "Film & TV", "TV & series"]

      assert PlaceTopics.valid?("literature-and-ideas/fields-of-thought/ai-and-computing")
      assert PlaceTopics.valid?("crafts-and-design/design-and-fashion/stationery-and-paper-goods")
      assert PlaceTopics.valid?("music-and-performance/music/electronic-and-ambient")
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

  describe "finds and tastes on the same tree" do
    @ai "literature-and-ideas/fields-of-thought/ai-and-computing"
    @mind "literature-and-ideas/fields-of-thought/mind-and-cognitive-science"
    @ambient "music-and-performance/music/electronic-and-ambient"

    # Replies as stub_reply/1 does, and sends the system prompt it was given
    # back to the test.
    defp stub_things(verdicts) do
      test = self()

      Req.Test.stub(TravelingPoet.PlaceClassifier, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        [%{"content" => system} | _] = Jason.decode!(body)["messages"]
        send(test, {:system_prompt, system})

        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"content" => Jason.encode!(%{"places" => verdicts})}}]
        })
      end)
    end

    setup do
      poet = poet_fixture(user_fixture())
      topic = topic_fixture(poet, %{label: "Embodied minds"})
      entry = published_entry_fixture(poet, %{entry_date: ~D[2026-09-20]})
      excursion_fixture(poet, topic, entry)

      {:ok, [talk]} =
        TravelingPoet.Topics.replace_finds(entry, [
          %{
            "name" => "Shanahan on embodiment",
            "url" => "https://example.com/t",
            "kind" => "talk"
          }
        ])

      %{poet: poet, topic: topic, entry: entry, talk: talk}
    end

    test "a find is filed by what it is about, with the things instructions",
         %{entry: entry, talk: talk} do
      stub_things([%{"id" => talk.id, "topics" => [@ai, @mind], "type" => "other"}])

      assert TopicTagging.tag_finds(entry.id, api_key: "k") == 1
      assert_receive {:system_prompt, system}
      assert system =~ "what it is ABOUT"
      refute system =~ "somewhere a visitor could go"

      talk = Repo.get!(TravelingPoet.Topics.Find, talk.id)
      assert {talk.topic, talk.second_topic} == {@ai, @mind}
      assert talk.topics_classified_at

      # the poet re-sends its list: the talk keeps its place on the tree
      {:ok, [again]} =
        TravelingPoet.Topics.replace_finds(entry, [
          %{
            "name" => "Shanahan on embodiment",
            "url" => "https://example.com/t2",
            "kind" => "talk"
          }
        ])

      assert again.topic == @ai
      assert TopicTagging.tag_finds(entry.id, api_key: "k") == 0
    end

    test "a find the poet called 'other' takes the classifier's kind; a chosen kind stays",
         %{entry: entry} do
      {:ok, [show, talk]} =
        TravelingPoet.Topics.replace_finds(entry, [
          %{"name" => "Solwata", "url" => "https://example.com/s", "kind" => "other"},
          %{"name" => "A talk", "url" => "https://example.com/t", "kind" => "talk"}
        ])

      stub_things([
        %{"id" => show.id, "topics" => [@ai], "type" => "event"},
        %{"id" => talk.id, "topics" => [@ai], "type" => "paper"}
      ])

      assert TopicTagging.tag_finds(entry.id, api_key: "k") == 2
      assert_receive {:system_prompt, system}
      assert system =~ "what kind of thing it is"
      assert Repo.get!(TravelingPoet.Topics.Find, show.id).kind == "event"
      assert Repo.get!(TravelingPoet.Topics.Find, talk.id).kind == "talk"
    end

    test "a taste gets its subjects; new words clear them for a fresh look", %{poet: poet} do
      taste = topic_fixture(poet, %{label: "Colleen, DakhaBrakha", domain: "music"})
      stub_things([%{"id" => taste.id, "topics" => [@ambient], "type" => "other"}])

      assert TopicTagging.tag_topic(taste.id, api_key: "k") == 1
      taste = Repo.get!(TravelingPoet.Topics.Topic, taste.id)
      assert taste.subject == @ambient

      {:ok, same} = TravelingPoet.Topics.update(taste, %{every_days: 10})
      assert same.subject == @ambient

      {:ok, reworded} = TravelingPoet.Topics.update(same, %{label: "Arvo Part"})
      assert reworded.subject == nil
      assert reworded.subjects_classified_at == nil
    end

    test "the backfill covers finds and topics, dry run unless told to commit",
         %{talk: talk, topic: topic} do
      stub_things([%{"id" => talk.id, "topics" => [@ai], "type" => "other"}])

      report = TopicTagging.backfill(target: :finds, api_key: "k")
      assert report.committed == false
      assert report.classified == 1
      assert Repo.get!(TravelingPoet.Topics.Find, talk.id).topic == nil

      TopicTagging.backfill(target: :finds, api_key: "k", commit: true)
      assert Repo.get!(TravelingPoet.Topics.Find, talk.id).topic == @ai

      stub_things([%{"id" => topic.id, "topics" => [@mind], "type" => "other"}])
      TopicTagging.backfill(target: :topics, api_key: "k", commit: true)
      assert Repo.get!(TravelingPoet.Topics.Topic, topic.id).subject == @mind
    end
  end
end
