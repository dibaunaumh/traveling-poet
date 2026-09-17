defmodule TravelingPoet.MarkersTest do
  use TravelingPoet.DataCase, async: false

  import Ecto.Query
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Journal, Markers, Repo, Usage}
  alias TravelingPoet.Journal.Marker
  alias TravelingPoet.Markers.Delivery

  # A provisioned owner with credits, so delivery's gates all pass by default.
  defp ready_poet(user_attrs \\ %{credits: 5}) do
    user = agent_user_fixture(user_attrs)
    poet = poet_fixture(user)
    entry = published_entry_fixture(poet)
    {:ok, _} = Journal.replace_sections(entry, [%{kind: "description", body: "a long day"}])
    {user, poet, entry}
  end

  defp text_marker(user, entry, attrs \\ %{}) do
    {:ok, marker} =
      Markers.add_marker(
        user,
        entry,
        Map.merge(
          %{
            "kind" => "boring",
            "target" => "text",
            "quote" => "a long day",
            "prefix" => "",
            "suffix" => "",
            "section_kind" => "description",
            "section_position" => "0"
          },
          attrs
        )
      )

    marker
  end

  defp backdate(entry, minutes) do
    at =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-minutes * 60, :second)
      |> NaiveDateTime.truncate(:second)

    Repo.update_all(from(m in Marker, where: m.journal_entry_id == ^entry.id),
      set: [inserted_at: at]
    )
  end

  describe "markers" do
    test "add, list, payload, remove" do
      {user, _poet, entry} = ready_poet()
      marker = text_marker(user, entry)

      assert marker.section_position == 0
      assert marker.quote == "a long day"
      assert [%Marker{id: id}] = Markers.list_markers(entry.id)
      assert id == marker.id

      assert [%{kind: "boring", label: "Boring", sent: false, quote: "a long day"}] =
               Markers.payload(Markers.list_markers(entry.id))

      assert {:ok, _} = Markers.remove_marker(user.id, to_string(marker.id))
      assert Markers.list_markers(entry.id) == []
    end

    test "an identical pending marker is not duplicated" do
      {user, _poet, entry} = ready_poet()
      a = text_marker(user, entry)
      b = text_marker(user, entry)
      assert a.id == b.id
      assert length(Markers.list_markers(entry.id)) == 1
    end

    test "only the owner can remove a marker" do
      {user, _poet, entry} = ready_poet()
      marker = text_marker(user, entry)
      other = user_fixture()
      assert {:error, :not_found} = Markers.remove_marker(other.id, marker.id)
      assert length(Markers.list_markers(entry.id)) == 1
    end

    test "rejects unknown kinds, blank text quotes, and illustrations without media" do
      {user, _poet, entry} = ready_poet()

      assert {:error, _} =
               Markers.add_marker(user, entry, %{"kind" => "meh", "target" => "section"})

      assert {:error, cs} =
               Markers.add_marker(user, entry, %{
                 "kind" => "boring",
                 "target" => "text",
                 "quote" => "   "
               })

      assert %{quote: _} = errors_on(cs)

      assert {:error, cs} =
               Markers.add_marker(user, entry, %{"kind" => "boring", "target" => "illustration"})

      assert %{media_id: _} = errors_on(cs)
    end

    test "illustration and section markers" do
      {user, poet, entry} = ready_poet()
      media = media_fixture(poet, %{journal_entry_id: entry.id})

      assert {:ok, m} =
               Markers.add_marker(user, entry, %{
                 "kind" => "drawing_needed",
                 "target" => "illustration",
                 "section_kind" => "illustration",
                 "media_id" => to_string(media.id)
               })

      assert m.media_id == media.id

      assert {:ok, s} =
               Markers.add_marker(user, entry, %{
                 "kind" => "interesting",
                 "target" => "section",
                 "section_kind" => "poem",
                 "section_position" => 2
               })

      assert s.section_position == 2
    end

    test "recent_payload and counts_since see this poet's markers only" do
      {user, poet, entry} = ready_poet()
      text_marker(user, entry)
      text_marker(user, entry, %{"kind" => "beautiful", "quote" => "day"})
      {other_user, _other_poet, other_entry} = ready_poet()
      text_marker(other_user, other_entry)

      since = DateTime.add(DateTime.utc_now(), -1, :hour)
      payload = Markers.recent_payload(poet.id, since)
      assert length(payload) == 2
      assert Enum.all?(payload, &(&1.entry_date == entry.entry_date))
      assert Markers.counts_since(poet.id, since) == %{"boring" => 1, "beautiful" => 1}
    end

    test "an Other feedback marker carries the reader's note into the digest" do
      {user, _poet, entry} = ready_poet()
      other = text_marker(user, entry, %{"kind" => "other", "note" => "  first draft  "})
      assert other.note == "first draft"

      assert {:ok, updated} = Markers.update_note(user.id, other.id, "Tell me about the bakery")
      assert updated.note == "Tell me about the bakery"
      assert [%{kind: "other", note: "Tell me about the bakery"}] = Markers.payload([updated])

      stranger = user_fixture()
      assert {:error, :not_found} = Markers.update_note(stranger.id, other.id, "nope")

      backdate(entry, Delivery.quiet_minutes() + 1)
      [due] = Delivery.due()
      {:ok, message} = Delivery.claim(due)

      assert message =~
               ~s([Other feedback] the description section: "a long day" -> your companion wrote: "Tell me about the bakery")
    end

    test "mark_sent takes markers out of the pending set" do
      {user, _poet, entry} = ready_poet()
      marker = text_marker(user, entry)
      assert [{_, _, [_]}] = Markers.pending_by_entry()

      Markers.mark_sent([marker.id])
      assert Markers.pending_by_entry() == []
      assert [%{sent: true}] = Markers.payload(Markers.list_markers(entry.id))
    end
  end

  describe "Delivery.due/1" do
    test "waits out the quiet period, then is due" do
      {user, _poet, entry} = ready_poet()
      text_marker(user, entry)

      assert Delivery.due() == []

      backdate(entry, Delivery.quiet_minutes() + 1)
      assert [%{entry: %{id: id}, markers: [_]}] = Delivery.due()
      assert id == entry.id
    end

    test "a fresh marker resets the clock for the whole entry" do
      {user, _poet, entry} = ready_poet()
      text_marker(user, entry)
      backdate(entry, Delivery.quiet_minutes() + 1)
      text_marker(user, entry, %{"kind" => "beautiful", "quote" => "day"})

      assert Delivery.due() == []
    end

    test "not while the sprite is busy with a run or a chat" do
      {user, _poet, entry} = ready_poet()
      text_marker(user, entry)
      backdate(entry, Delivery.quiet_minutes() + 1)

      {:ok, _} = Usage.record(user.id, "daily_run_attempt")
      assert Delivery.due() == []
    end

    test "not within minutes of a chat turn" do
      {user, _poet, entry} = ready_poet()
      text_marker(user, entry)
      backdate(entry, Delivery.quiet_minutes() + 1)

      {:ok, _} = Usage.record(user.id, "chat_turn")
      assert Delivery.due() == []
    end

    test "not for an unprovisioned user, an exhausted one, or a draft entry" do
      user = user_fixture(%{credits: 5})
      poet = poet_fixture(user)
      entry = published_entry_fixture(poet)
      text_marker(user, entry)
      backdate(entry, Delivery.quiet_minutes() + 1)
      assert Delivery.due() == []

      {user, _poet, entry} = ready_poet(%{})
      text_marker(user, entry)
      backdate(entry, Delivery.quiet_minutes() + 1)
      assert Delivery.due() == []

      {user, poet, _entry} = ready_poet()
      draft = entry_fixture(poet, %{entry_date: Date.add(Date.utc_today(), 1)})
      text_marker(user, draft)
      backdate(draft, Delivery.quiet_minutes() + 1)
      assert Delivery.due() == []
    end
  end

  describe "Delivery.claim/2" do
    test "stamps the markers, records the attempt, and writes the digest" do
      {user, poet, entry} = ready_poet()
      text_marker(user, entry)

      text_marker(user, entry, %{
        "kind" => "drawing_needed",
        "target" => "section",
        "section_kind" => "poem",
        "section_position" => 1,
        "quote" => ""
      })

      backdate(entry, Delivery.quiet_minutes() + 1)
      [due] = Delivery.due()

      {:ok, message} = Delivery.claim(due)

      assert message =~ "/revise-entry #{Date.to_iso8601(entry.entry_date)}"
      assert message =~ "latest published entry: revise it"
      assert message =~ ~s([Boring] the description section: "a long day")
      assert message =~ "[Drawing needed] the poem section (the whole section)"
      assert message =~ poet.name

      assert Enum.all?(Markers.list_markers(entry.id), &(&1.sent_at != nil))
      assert Usage.today_count(user.id, Delivery.attempt_kind()) == 1
      assert Delivery.due() == []
    end

    test "an older entry is learn-only" do
      {user, poet, entry} = ready_poet()
      _later = published_entry_fixture(poet, %{entry_date: Date.add(Date.utc_today(), 1)})
      text_marker(user, entry)
      backdate(entry, Delivery.quiet_minutes() + 1)
      [due] = Delivery.due()

      {:ok, message} = Delivery.claim(due)
      assert message =~ "not your latest entry: do not rewrite it"
    end

    test "the daily revisions cap holds" do
      {user, _poet, entry} = ready_poet()

      for _ <- 1..4, do: {:ok, _} = Usage.record(user.id, Delivery.attempt_kind())
      # push those attempts out of the busy window (15 min) but not out of
      # today: a flat hour back made them yesterday's for the first hour of
      # every UTC day, and the cap stopped counting them
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      midnight = DateTime.new!(DateTime.to_date(now), ~T[00:00:00], "Etc/UTC")
      earlier = DateTime.add(now, -16, :minute)
      at = if DateTime.compare(earlier, midnight) == :lt, do: midnight, else: earlier

      Repo.update_all(TravelingPoet.Usage.UsageEvent, set: [occurred_at: at])

      text_marker(user, entry)
      backdate(entry, Delivery.quiet_minutes() + 1)
      assert Delivery.due() == []
    end
  end
end
