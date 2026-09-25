defmodule TravelingPoet.AffinityTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, Affinity, Journal, Reading, Repo, Topics}
  alias TravelingPoet.Affinity.Layout
  alias TravelingPoet.Guide.PlaceTopics
  alias TravelingPoet.Journal.{Paragraphs, ParagraphSubject, Reaction}

  @history "history-and-heritage/history-museums/local-history"
  @craft "crafts-and-design/ceramics-and-tiles/pottery"
  @now ~U[2026-09-25 12:00:00Z]

  @p1 "The town grew around the salt works in the twelfth century, and its streets still follow the old brine channels."
  @p2 "A potter on the square throws bowls the way her grandmother did, with ash glaze from the village's own kilns."

  describe "score/2" do
    test "sums signals by subject, halving every 30 days; standing signals do not fade" do
      signals = [
        %{at: ~D[2026-09-25], weight: 3, subjects: [{"a", 1.0}]},
        %{at: ~D[2026-08-26], weight: 2, subjects: [{"a", 0.5}, {"b", 0.5}]},
        %{at: ~D[2026-07-27], weight: -2, subjects: [{"c", 1.0}]},
        %{at: :now, weight: 4, subjects: [{"d", 1.0}]}
      ]

      assert Affinity.score(signals, @now) == [{"d", 4.0}, {"a", 3.5}, {"b", 0.5}, {"c", -0.5}]
    end
  end

  test "reading through is at least half the time the paragraph takes" do
    assert Affinity.read_through?(%{chars: 170, ms: 5_000})
    refute Affinity.read_through?(%{chars: 170, ms: 4_000})
  end

  describe "marked_paragraphs/2" do
    setup do
      %{
        paragraphs:
          Paragraphs.of_markdown(@p1 <> "\n\n" <> @p2)
          |> Enum.map(&Map.put(&1, :section_kind, "description"))
      }
    end

    test "a quote finds its paragraph, a selection across two finds both", %{paragraphs: ps} do
      assert [%{text: @p1}] =
               Affinity.marked_paragraphs(%{target: "text", quote: "old  brine\nchannels"}, ps)

      across = @p1 <> "\n\n" <> @p2
      assert length(Affinity.marked_paragraphs(%{target: "text", quote: across}, ps)) == 2
    end

    test "a section marker covers the section", %{paragraphs: ps} do
      assert length(
               Affinity.marked_paragraphs(%{target: "section", section_kind: "description"}, ps)
             ) == 2

      assert Affinity.marked_paragraphs(%{target: "section", section_kind: "art_culture"}, ps) ==
               []
    end
  end

  describe "profile/2" do
    setup do
      user = user_fixture()
      poet = poet_fixture(user)
      entry = entry_fixture(poet, %{entry_date: ~D[2026-09-20]})

      {:ok, _} =
        Journal.replace_sections(entry, [%{kind: "description", body: @p1 <> "\n\n" <> @p2}])

      for {text, topic} <- [{@p1, @history}, {@p2, @craft}] do
        Repo.insert!(%ParagraphSubject{
          poet_id: poet.id,
          journal_entry_id: entry.id,
          key: Paragraphs.key(text),
          topic: topic,
          classified_at: DateTime.truncate(@now, :second)
        })
      end

      %{user: user, poet: poet, entry: entry}
    end

    test "reading, markers and topics add up; a boring mark counts against",
         %{user: user, poet: poet, entry: entry} do
      Reading.record(user, entry, %{Paragraphs.key(@p1) => 10_000}, ~D[2026-09-25])
      marker_fixture(user, entry, "interesting", "salt works")
      marker_fixture(user, entry, "boring", "ash glaze")

      {:ok, topic} = Topics.create(poet.id, %{label: "Pottery"})

      {:ok, _} =
        topic |> Ecto.Changeset.change(status: "active", subject: @craft) |> Repo.update()

      scores = Map.new(Affinity.profile(user, @now), &{&1.path, &1.score})
      assert_in_delta scores[@history], 1 + 3, 0.01
      assert_in_delta scores[@craft], 4 - 3, 0.01
    end

    test "a reaction spreads over the page's subjects", %{user: user, entry: entry} do
      Repo.insert!(%Reaction{
        journal_entry_id: entry.id,
        user_id: user.id,
        kind: "not_for_me",
        visibility: "private"
      })

      scores = Map.new(Affinity.profile(user, @now), &{&1.path, &1.score})
      assert_in_delta scores[@history], -1.0, 0.1
      assert_in_delta scores[@craft], -1.0, 0.1
    end

    test "only the owner's own signals count", %{entry: entry} do
      stranger = user_fixture()
      marker_fixture(stranger, entry, "interesting", "salt works")
      assert Affinity.profile(stranger, @now) == []
    end

    test "reading counts only with the switch on", %{user: user, entry: entry} do
      Reading.record(user, entry, %{Paragraphs.key(@p1) => 10_000}, ~D[2026-09-25])
      {:ok, off} = Accounts.update_user(user, %{reading_signals: false})
      assert Affinity.profile(off, @now) == []
    end

    test "a dismissed subject stays off until restored", %{user: user, entry: entry} do
      marker_fixture(user, entry, "interesting", "salt works")
      assert [%{path: @history}] = Affinity.top(user, 8, @now)

      Affinity.dismiss(user, @history)
      Affinity.dismiss(user, @history)
      assert Affinity.top(user, 8, @now) == []
      assert [%{path: @history}] = Affinity.dismissed(user)

      Affinity.restore(user, @history)
      assert [%{path: @history}] = Affinity.top(user, 8, @now)
    end
  end

  test "the layout puts every topic at its own fixed point on the page" do
    %{regions: regions, points: points} = Layout.layout()

    assert length(regions) == 12
    assert Map.keys(points) |> Enum.sort() == PlaceTopics.paths()
    assert points |> Map.values() |> Enum.uniq() |> length() == map_size(points)

    for {x, y} <- Map.values(points) do
      assert x > 0 and x < Layout.width() and y > 0 and y < Layout.height()
    end
  end

  defp marker_fixture(user, entry, kind, quote) do
    Repo.insert!(%Journal.Marker{
      journal_entry_id: entry.id,
      user_id: user.id,
      kind: kind,
      target: "text",
      section_kind: "description",
      quote: quote
    })
  end
end
