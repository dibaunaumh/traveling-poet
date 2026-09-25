defmodule TravelingPoet.ParagraphSubjectsTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Journal, Repo}
  alias TravelingPoet.Guide.TopicTagging
  alias TravelingPoet.Journal.{ParagraphSubject, Paragraphs}

  @jazz "music-and-performance/music/jazz"
  @weaving "crafts-and-design/textiles/weaving-and-silk"

  @one "In the evening a trio played **bebop** in [Club Alegria](/x), the bass ![spot](/media/9) walking under a trumpet."
  @two "Next door, a weaver showed me how silk is dyed with indigo and hung to dry in the lane."

  test "a paragraph is keyed by what a reader sees of it" do
    [p] = Paragraphs.of_markdown(@one)
    seen = "In the evening a trio played bebop in Club Alegria, the bass walking under a trumpet."
    assert p.text == seen

    # the browser computes the same from the rendered <p>'s textContent
    expected = :crypto.hash(:sha256, seen) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    assert p.key == expected
    assert Paragraphs.key("  " <> seen <> "\n") == expected

    # headings, captions and other short lines are not prose
    assert Paragraphs.of_markdown("Day 4.\n\n" <> @two) |> length() == 1
  end

  test "prose sections only, in reading order; a poem is left out" do
    sections = [
      %{kind: "poem", position: 0, body: @two <> " (a stanza)"},
      %{kind: "art_culture", position: 2, body: @two},
      %{kind: "description", position: 1, body: @one},
      %{kind: "illustration", position: 3, body: nil}
    ]

    assert [%{section_kind: "description"}, %{section_kind: "art_culture"}] =
             Paragraphs.of_sections(Enum.map(sections, &struct(Journal.Section, &1)))
  end

  describe "tagging" do
    defp stub(verdicts_by_text) do
      test = self()

      Req.Test.stub(TravelingPoet.PlaceClassifier, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        [_system, %{"content" => user}] = Jason.decode!(body)["messages"]
        rows = user |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "id="))
        send(test, {:asked, length(rows)})

        verdicts =
          Enum.map(rows, fn row ->
            [_, id] = Regex.run(~r/^id=(\d+)/, row)
            topic = Enum.find_value(verdicts_by_text, fn {text, t} -> row =~ text && t end)
            %{"id" => String.to_integer(id), "topics" => List.wrap(topic), "type" => "other"}
          end)

        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"content" => Jason.encode!(%{"places" => verdicts})}}]
        })
      end)
    end

    setup do
      poet = poet_fixture(user_fixture())
      entry = published_entry_fixture(poet, %{entry_date: ~D[2026-09-20], place_name: "Lisbon"})

      {:ok, _} =
        Journal.replace_sections(entry, [
          %{kind: "description", body: @one},
          %{kind: "art_culture", body: @two}
        ])

      %{entry: entry}
    end

    test "a published page's paragraphs get subjects; a revision tags only what changed",
         %{entry: entry} do
      stub([{"bebop", @jazz}, {"silk", @weaving}])
      assert TopicTagging.tag_paragraphs(entry.id, api_key: "k") == 2
      assert_receive {:asked, 2}

      rows = Repo.all(ParagraphSubject) |> Map.new(&{&1.section_kind, &1})
      assert rows["description"].topic == @jazz
      assert rows["art_culture"].topic == @weaving
      assert rows["description"].key == hd(Paragraphs.of_markdown(@one)).key

      # the poet revises one paragraph; the other keeps its row untouched
      revised =
        "Next door, a weaver showed me how silk is dyed with woad, not indigo, in the lane."

      {:ok, _} =
        Journal.replace_sections(entry, [
          %{kind: "description", body: @one},
          %{kind: "art_culture", body: revised}
        ])

      assert TopicTagging.tag_paragraphs(entry.id, api_key: "k") == 1
      assert_receive {:asked, 1}
      assert Repo.aggregate(ParagraphSubject, :count) == 3
    end

    test "a paragraph about nothing in particular is classified, with no subject",
         %{entry: entry} do
      stub([{"bebop", @jazz}])
      assert TopicTagging.tag_paragraphs(entry.id, api_key: "k") == 2
      assert Repo.get_by!(ParagraphSubject, section_kind: "art_culture").topic == nil
      # and is not sent again
      assert TopicTagging.tag_paragraphs(entry.id, api_key: "k") == 0
    end

    test "the backfill is a dry run unless told to commit", %{entry: entry} do
      stub([{"bebop", @jazz}, {"silk", @weaving}])

      report = TopicTagging.backfill(target: :paragraphs, api_key: "k")
      assert report.places == 2
      assert report.committed == false
      assert Repo.aggregate(ParagraphSubject, :count) == 0

      TopicTagging.backfill(target: :paragraphs, api_key: "k", commit: true)
      assert Repo.aggregate(ParagraphSubject, :count) == 2
      assert TopicTagging.backfill(target: :paragraphs, api_key: "k").places == 0
      assert entry.id
    end

    test "the async hook is off unless switched on", %{entry: entry} do
      assert TopicTagging.tag_paragraphs_async(entry.id) == :disabled
    end
  end
end
