defmodule TravelingPoet.ExcursionsTest do
  @moduledoc """
  The decision's inputs and the app-owned bookkeeping around an excursion:
  which topic is due, what a chat request does, how an entry gets linked,
  and how a day off the road is kept out of the stay clock.
  """
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Journal, Poets, Topics}

  defp days_ago(n), do: DateTime.utc_now() |> DateTime.add(-n, :day) |> DateTime.truncate(:second)

  defp excursion_entry(poet, topic, day_offset) do
    date = Date.add(Date.utc_today(), -day_offset)
    entry = published_entry_fixture(poet, %{entry_date: date, title: "Off the road"})
    excursion_fixture(poet, topic, entry)
  end

  setup do
    user = user_fixture()
    poet = poet_fixture(user, %{arrived_at: days_ago(1)})
    %{poet: poet}
  end

  describe "due_topic/2" do
    test "the longest-waiting active topic goes first, in the companion's order", %{poet: poet} do
      a = topic_fixture(poet, %{label: "Embodied minds"})
      b = topic_fixture(poet, %{label: "Kit airplanes"})
      today = Date.utc_today()

      assert Topics.due_topic(poet.id, today).id == a.id

      excursion_entry(poet, a, 0)
      assert Topics.due_topic(poet.id, today).id == b.id

      excursion_entry(poet, b, 1)
      # both taken within the week: nothing due
      assert Topics.due_topic(poet.id, today) == nil
      # a week on, the one taken longest ago
      assert Topics.due_topic(poet.id, Date.add(today, 7)).id == b.id
    end

    test "cadence is per topic; paused and proposed topics never come up", %{poet: poet} do
      slow = topic_fixture(poet, %{label: "Ceramics", every_days: 14})
      excursion_entry(poet, slow, 8)
      today = Date.utc_today()
      assert Topics.due_topic(poet.id, today) == nil

      paused = topic_fixture(poet, %{label: "Kit airplanes"})
      {:ok, _} = Topics.pause(paused)
      {:ok, _proposed, false} = Topics.propose(poet.id, %{label: "Embodied minds"})
      assert Topics.due_topic(poet.id, today) == nil

      assert Topics.due_topic(poet.id, Date.add(today, 6)).id == slow.id
    end
  end

  test "yesterday's excursion is remembered; a queued chat request waits its turn", %{poet: poet} do
    topic = topic_fixture(poet, %{label: "Kit airplanes"})
    today = Date.utc_today()

    refute Topics.excursion_yesterday?(poet.id, today)
    excursion_entry(poet, topic, 1)
    assert Topics.excursion_yesterday?(poet.id, today)

    assert Topics.queued_chat_excursion(poet.id) == nil
    queued = excursion_fixture(poet, topic, nil, %{requested_destination: "Oshkosh"})
    assert Topics.queued_chat_excursion(poet.id).id == queued.id
    assert queued.status == "queued"
    assert queued.source == "chat"
  end

  test "an excursion day does not count as a day at the place", %{poet: poet} do
    {:ok, poet} = Poets.update_poet(poet, %{arrived_at: days_ago(3)})
    topic = topic_fixture(poet, %{label: "Kit airplanes"})

    assert Poets.days_here(poet) == 3
    excursion_entry(poet, topic, 2)
    assert Poets.days_here(poet) == 2
  end

  describe "link_entry/2" do
    test "claims the queued chat request for the topic and clears the place", %{poet: poet} do
      topic = topic_fixture(poet, %{label: "Kit airplanes"})
      queued = excursion_fixture(poet, topic, nil, %{requested_destination: "Oshkosh"})
      entry = entry_fixture(poet, %{place_name: "Lisbon", lat: 1.0, lng: 2.0})

      {:ok, linked} = Topics.link_entry(entry, %{"topic_id" => to_string(topic.id)})
      assert linked.id == queued.id
      assert linked.status == "written"
      assert linked.scheduled_for == entry.entry_date
      assert linked.journal_entry_id == entry.id

      reloaded = Journal.get_entry!(entry.id)
      assert is_nil(reloaded.place_name)
      assert is_nil(reloaded.lat)

      # the same entry again is the same row, not a second excursion
      {:ok, again} = Topics.link_entry(entry, %{"excursion_id" => linked.id})
      assert again.id == linked.id
      assert Topics.list_queued(poet.id) == []
    end

    test "with no request pending the app's own row is created", %{poet: poet} do
      topic = topic_fixture(poet, %{label: "Kit airplanes"})
      entry = entry_fixture(poet)

      {:ok, linked} = Topics.link_entry(entry, %{"topic_id" => topic.id})
      assert linked.source == "app"
      assert linked.topic.id == topic.id

      {:ok, published} = Journal.publish_entry(entry)
      assert Topics.get_excursion_for_entry(published.id).status == "published"
      assert Topics.published_excursions_before(topic.id, Date.add(entry.entry_date, 1)) == 1
    end

    test "a wrong id is loud, and no id means a day at the place", %{poet: poet} do
      entry = entry_fixture(poet)
      assert {:error, :unknown_topic} = Topics.link_entry(entry, %{"topic_id" => 999})
      assert {:error, :unknown_excursion} = Topics.link_entry(entry, %{"excursion_id" => 999})
      assert {:ok, nil} = Topics.link_entry(entry, %{})
      assert Journal.get_entry!(entry.id).place_name == "Lisbon, Portugal"
    end
  end

  test "replace_finds keeps a drawing across a re-put when the find keeps its name", %{poet: poet} do
    topic = topic_fixture(poet, %{label: "Kit airplanes"})
    entry = entry_fixture(poet)
    excursion_fixture(poet, topic, entry)
    media = media_fixture(poet)

    {:ok, [find]} =
      Topics.replace_finds(entry, [%{"name" => "RV-15 talk", "url" => "https://example.com/rv15"}])

    {:ok, _} = Topics.attach_find_media(find, media.id)

    {:ok, [kept, new]} =
      Topics.replace_finds(entry, [
        %{name: "RV-15 talk", url: "https://example.com/rv15", kind: "keynote"},
        %{name: "Kit prices", url: "https://example.com/prices", kind: "product"}
      ])

    assert kept.media_id == media.id
    # an unknown kind is coerced, never fatal
    assert kept.kind == "other"
    assert new.kind == "product"
    assert is_nil(new.media_id)
  end
end
