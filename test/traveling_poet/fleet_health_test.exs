defmodule TravelingPoet.FleetHealthTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{DailyJourneyScheduler, FleetHealth, Journal, Usage}

  defp publish(poet, date, attrs) do
    {:ok, entry} = Journal.upsert_entry(poet.id, date, attrs)
    {:ok, entry} = Journal.publish_entry(entry)
    entry
  end

  # publish_entry stamps published_at with "now"; back-date it to age an entry.
  defp age_entry(entry, hours) do
    published_at = DateTime.utc_now() |> DateTime.add(-hours, :hour) |> DateTime.truncate(:second)

    entry
    |> Ecto.Changeset.change(published_at: published_at)
    |> TravelingPoet.Repo.update!()
  end

  defp row_for(poet), do: Enum.find(FleetHealth.report(), &(&1.poet.id == poet.id))

  test "a poet that published today is ok" do
    user = user_fixture(%{sprite_provisioned: true})
    poet = poet_fixture(user, %{status: "active"})
    publish(poet, Date.utc_today(), %{place_name: "Lisbon, Portugal"})

    assert row_for(poet).status == :ok
  end

  test "an overdue poet is late while attempts remain, failing once they are spent" do
    user = user_fixture(%{sprite_provisioned: true})
    poet = poet_fixture(user, %{status: "active"})

    publish(poet, Date.add(Date.utc_today(), -2), %{place_name: "Kyoto, Japan"})
    |> age_entry(40)

    assert row_for(poet).status == :late

    for _ <- 1..DailyJourneyScheduler.max_attempts_per_day() do
      {:ok, _} = Usage.record(user.id, "daily_run_attempt")
    end

    assert row_for(poet).status == :failing
    assert Enum.any?(FleetHealth.problems(), &(&1.poet.id == poet.id))
  end

  test "a poet that has never published is a problem, a paused one is not" do
    user = user_fixture(%{sprite_provisioned: true})
    poet = poet_fixture(user, %{status: "active"})
    assert row_for(poet).status == :never_published
    assert Enum.any?(FleetHealth.problems(), &(&1.poet.id == poet.id))

    {:ok, paused} = TravelingPoet.Poets.update_poet(poet, %{status: "paused"})
    assert row_for(paused).status == :inactive
    refute Enum.any?(FleetHealth.problems(), &(&1.poet.id == poet.id))
  end

  test "drift is flagged when the map has moved past the newest entry" do
    user = user_fixture(%{sprite_provisioned: true})

    poet =
      poet_fixture(user, %{status: "active", current_place_name: "Nara, Nara Prefecture, Japan"})

    publish(poet, Date.utc_today(), %{place_name: "Kyoto, Kyoto Prefecture, Japan"})

    row = row_for(poet)
    assert row.drifted?
    assert row.entry_place == "Kyoto, Kyoto Prefecture, Japan"
    assert row.current_place == "Nara, Nara Prefecture, Japan"
    # still healthy — it published today; drift is a display fact, not a failure
    assert row.status == :ok
    assert Enum.any?(FleetHealth.drifted(), &(&1.poet.id == poet.id))
  end

  test "no drift when the newest entry matches the map" do
    user = user_fixture(%{sprite_provisioned: true})
    poet = poet_fixture(user, %{status: "active", current_place_name: "Lisbon, Portugal"})
    publish(poet, Date.utc_today(), %{place_name: "Lisbon, Portugal"})

    refute row_for(poet).drifted?
  end
end
