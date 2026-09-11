defmodule TravelingPoet.JournalTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Journal, Poets}
  alias TravelingPoet.Journal.Media

  setup do
    user = user_fixture()
    poet = poet_fixture(user)
    %{user: user, poet: poet}
  end

  test "illustrations require at least one http(s) source link", %{poet: poet} do
    base = %{
      poet_id: poet.id,
      s3_key: "poets/#{poet.id}/media/x.png",
      content_type: "image/png",
      kind: "illustration"
    }

    assert {:error, changeset} = Journal.create_media(base)
    assert %{sources: [_ | _]} = errors_on(changeset)

    assert {:error, _} =
             Journal.create_media(
               Map.put(base, :sources, %{"items" => [%{"url" => "ftp://nope", "label" => "x"}]})
             )

    assert {:ok, %Media{}} =
             Journal.create_media(
               Map.put(base, :sources, %{
                 "items" => [
                   %{"url" => "https://commons.wikimedia.org/wiki/File:X.jpg", "label" => "X"}
                 ]
               })
             )
  end

  test "poet avatars don't require sources", %{poet: poet} do
    assert {:ok, _} =
             Journal.create_media(%{
               poet_id: poet.id,
               s3_key: "poets/#{poet.id}/media/avatar.png",
               content_type: "image/png",
               kind: "poet_avatar"
             })
  end

  test "move_to closes the previous path point and updates current_*", %{poet: poet} do
    {:ok, _} = Poets.move_to(poet, %{lat: 40.0, lng: -8.0, place_name: "Coimbra"})
    poet = Poets.get_poet!(poet.id)
    {:ok, _} = Poets.move_to(poet, %{lat: 41.15, lng: -8.61, place_name: "Porto"})

    points = Poets.list_path_points(poet.id)
    assert [first, second] = points
    assert first.place_name == "Coimbra"
    assert first.departed_at != nil
    assert second.place_name == "Porto"
    assert second.departed_at == nil

    poet = Poets.get_poet!(poet.id)
    assert poet.current_place_name == "Porto"
  end

  test "publish broadcasts on poet and global topics", %{poet: poet} do
    Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "poet:#{poet.id}")
    Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "journal:published")

    {:ok, entry} = Journal.upsert_entry(poet.id, Date.utc_today(), %{title: "T"})
    {:ok, _} = Journal.publish_entry(entry)

    assert_receive {:journal_published, entry_id}
    assert_receive {:journal_published, _poet_id, ^entry_id}
  end

  test "publishing again is a revision: published_at kept, no second notification",
       %{poet: poet} do
    Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "poet:#{poet.id}")
    Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "journal:published")

    {:ok, entry} = Journal.upsert_entry(poet.id, Date.utc_today(), %{title: "T"})
    {:ok, published} = Journal.publish_entry(entry)
    assert_receive {:journal_published, _}
    assert_receive {:journal_published, _, _}

    {:ok, revised} = Journal.publish_entry(published)

    assert revised.published_at == published.published_at
    assert_receive {:journal_revised, id}
    assert id == published.id
    refute_receive {:journal_published, _}
    refute_receive {:journal_published, _, _}
  end

  test "private feedback digest only includes private reactions", %{poet: poet, user: user} do
    {:ok, entry} = Journal.upsert_entry(poet.id, Date.utc_today(), %{})
    {:ok, _} = Journal.toggle_reaction(entry.id, user.id, "love", "private", "more like this")
    {:ok, _} = Journal.toggle_reaction(entry.id, user.id, "love", "public")

    since = DateTime.add(DateTime.utc_now(), -1, :hour)
    feedback = Journal.private_feedback_since(poet.id, since)

    assert [%{kind: "love", note: "more like this"}] = feedback
  end

  describe "journey day" do
    test "counts calendar days from the first published entry, gaps included", %{poet: poet} do
      assert Journal.first_published_date(poet.id) == nil

      # A draft before anything is published is Day 1 in waiting, not Day 0.
      draft = entry_fixture(poet, %{entry_date: ~D[2026-09-01]})
      assert Journal.journey_day(draft) == 1

      first = published_entry_fixture(poet, %{entry_date: ~D[2026-09-01]})
      published_entry_fixture(poet, %{entry_date: ~D[2026-09-02]})
      # 09-03 skipped: a rest day (or no credits) leaves a gap, it does not renumber
      fourth = published_entry_fixture(poet, %{entry_date: ~D[2026-09-04]})

      assert Journal.first_published_date(poet.id) == ~D[2026-09-01]
      assert Journal.journey_day(first) == 1
      assert Journal.journey_day(fourth) == 4
      assert Journal.journey_day(~D[2026-09-04], ~D[2026-09-01]) == 4
      assert Journal.journey_day(~D[2026-09-04], nil) == 1
    end

    test "a draft dated before the first published entry never goes below Day 1", %{poet: poet} do
      published_entry_fixture(poet, %{entry_date: ~D[2026-09-05]})
      earlier = entry_fixture(poet, %{entry_date: ~D[2026-09-02]})
      assert Journal.journey_day(earlier) == 1
    end
  end

  describe "entry_illustration/1" do
    test "prefers the illustration section's drawing, then an unattached one", %{poet: poet} do
      entry = entry_fixture(poet, %{entry_date: ~D[2026-09-01]})
      assert Journal.entry_illustration(entry) == nil

      loose = media_fixture(poet, %{journal_entry_id: entry.id})
      assert Journal.entry_illustration(entry).id == loose.id

      chosen = media_fixture(poet, %{journal_entry_id: entry.id})

      {:ok, _} =
        Journal.replace_sections(entry, [
          %{kind: "description", body: "words"},
          %{kind: "illustration", media_id: chosen.id}
        ])

      assert Journal.entry_illustration(entry).id == chosen.id
    end
  end
end
