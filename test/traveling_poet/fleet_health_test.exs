defmodule TravelingPoet.FleetHealthTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{DailyJourneyScheduler, FleetHealth, Journal, Usage}

  # Noon today, so tests can put a poet's publish hour either side of "now"
  # without depending on when the suite happens to run.
  defp noon do
    Date.utc_today() |> DateTime.new!(~T[12:00:00], "Etc/UTC")
  end

  defp publish(poet, date, attrs) do
    {:ok, entry} = Journal.upsert_entry(poet.id, date, attrs)
    {:ok, entry} = Journal.publish_entry(entry)
    entry
  end

  # publish_entry stamps published_at with "now"; move it to place an entry
  # relative to the poet's publish slot.
  defp published_at(entry, %DateTime{} = at) do
    entry
    |> Ecto.Changeset.change(published_at: DateTime.truncate(at, :second))
    |> TravelingPoet.Repo.update!()
  end

  defp poet_due_at(hour, attrs \\ %{}) do
    user = user_fixture(%{sprite_provisioned: true})

    poet_fixture(
      user,
      Map.merge(%{status: "active", settings: %{"journal_hour_utc" => hour}}, attrs)
    )
  end

  defp row_for(poet, now), do: Enum.find(FleetHealth.report(now), &(&1.poet.id == poet.id))

  test "published since today's slot is ok" do
    poet = poet_due_at(8)
    publish(poet, Date.utc_today(), %{place_name: "Lisbon, Portugal"})

    assert row_for(poet, noon()).status == :ok
  end

  test "yesterday's entry does not satisfy today's slot once it has passed" do
    poet = poet_due_at(8)

    publish(poet, Date.add(Date.utc_today(), -1), %{place_name: "Kyoto, Japan"})
    |> published_at(DateTime.add(noon(), -20, :hour))

    # The case the old flat-30h rule got wrong: only 20 hours have passed, but
    # the poet was due at 08:00 and it is now noon.
    assert row_for(poet, noon()).status == :late

    for _ <- 1..DailyJourneyScheduler.max_attempts_per_day() do
      {:ok, _} = Usage.record(poet.user_id, "daily_run_attempt")
    end

    assert row_for(poet, noon()).status == :failing
    assert Enum.any?(FleetHealth.problems(noon()), &(&1.poet.id == poet.id))
  end

  test "publishing early still settles the day" do
    poet = poet_due_at(8)

    # A catch-up run publishes well off the usual slot — 03:00 for a poet due
    # at 08:00. That is still today's entry, not a missed day.
    publish(poet, Date.utc_today(), %{place_name: "Lisbon, Portugal"})
    |> published_at(DateTime.add(noon(), -9, :hour))

    assert row_for(poet, noon()).status == :ok
  end

  test "a poet whose slot hasn't come round yet is ok on yesterday's entry" do
    poet = poet_due_at(20)

    publish(poet, Date.add(Date.utc_today(), -1), %{place_name: "Kyoto, Japan"})
    |> published_at(DateTime.add(noon(), -16, :hour))

    assert row_for(poet, noon()).status == :ok
    assert FleetHealth.problems(noon()) == []
  end

  test "never published: quiet before the slot, failing once attempts run out" do
    poet = poet_due_at(20)
    assert row_for(poet, noon()).status == :never_published
    assert FleetHealth.problems(noon()) == []

    due = poet_due_at(8)

    for _ <- 1..DailyJourneyScheduler.max_attempts_per_day() do
      {:ok, _} = Usage.record(due.user_id, "daily_run_attempt")
    end

    assert row_for(due, noon()).status == :failing
  end

  test "paused poets are inactive, never problems" do
    poet = poet_due_at(8)
    {:ok, paused} = TravelingPoet.Poets.update_poet(poet, %{status: "paused"})

    assert row_for(paused, noon()).status == :inactive
    assert FleetHealth.problems(noon()) == []
  end

  test "drift is flagged when the map has moved past the newest entry" do
    poet = poet_due_at(8, %{current_place_name: "Nara, Nara Prefecture, Japan"})
    publish(poet, Date.utc_today(), %{place_name: "Kyoto, Kyoto Prefecture, Japan"})

    row = row_for(poet, noon())
    assert row.drifted?
    assert row.entry_place == "Kyoto, Kyoto Prefecture, Japan"
    assert row.current_place == "Nara, Nara Prefecture, Japan"
    # still healthy — it published for today; drift is a display fact, not a failure
    assert row.status == :ok
    assert Enum.any?(FleetHealth.drifted(noon()), &(&1.poet.id == poet.id))
  end

  test "an excursion entry is named as one and never counts as drift" do
    poet = poet_due_at(8, %{current_place_name: "Lisbon, Portugal"})
    topic = topic_fixture(poet, %{label: "Kit airplanes"})
    entry = publish(poet, Date.utc_today(), %{place_name: "Lisbon, Portugal"})
    excursion_fixture(poet, topic, entry)

    row = row_for(poet, noon())
    assert row.entry_place == "excursion: Kit airplanes"
    assert row.excursion_label == "Kit airplanes"
    refute row.drifted?
    assert row.status == :ok
  end

  test "no drift when the newest entry matches the map" do
    poet = poet_due_at(8, %{current_place_name: "Lisbon, Portugal"})
    publish(poet, Date.utc_today(), %{place_name: "Lisbon, Portugal"})

    refute row_for(poet, noon()).drifted?
  end
end
