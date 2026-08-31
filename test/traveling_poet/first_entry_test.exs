defmodule TravelingPoet.FirstEntryTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{FirstEntry, Journal, Repo, Usage}
  alias TravelingPoet.Usage.UsageEvent

  import Ecto.Query

  defp attempts(user_id) do
    UsageEvent
    |> where(user_id: ^user_id, kind: "first_entry_attempt")
    |> select([e], count(e.id))
    |> Repo.one()
  end

  defp age_attempts(user_id, minutes) do
    occurred_at =
      DateTime.utc_now() |> DateTime.add(-minutes, :minute) |> DateTime.truncate(:second)

    UsageEvent
    |> where(user_id: ^user_id, kind: "first_entry_attempt")
    |> Repo.update_all(set: [occurred_at: occurred_at])
  end

  test "an unprovisioned sprite isn't ready to be kicked off" do
    user = user_fixture(%{sprite_provisioned: false})
    poet = poet_fixture(user)

    assert FirstEntry.ensure_started(user, poet) == :not_ready
    assert attempts(user.id) == 0
  end

  test "a poet that already published is done, and never fires again" do
    user = user_fixture(%{sprite_provisioned: true})
    poet = poet_fixture(user)

    {:ok, entry} = Journal.upsert_entry(poet.id, Date.utc_today(), %{title: "First"})
    {:ok, _} = Journal.publish_entry(entry)

    assert FirstEntry.ensure_started(user, poet) == :done
    assert attempts(user.id) == 0
    assert FirstEntry.pending() == []
  end

  test "a second call while one is in flight doesn't stack another run" do
    user = user_fixture(%{sprite_provisioned: true})
    poet = poet_fixture(user)

    # The LiveView fires on gateway connect; the watchdog ticks independently.
    # Both call this, and a reconnect loop could call it repeatedly.
    {:ok, _} = Usage.record(user.id, "first_entry_attempt")

    assert FirstEntry.ensure_started(user, poet) == :in_flight
    assert attempts(user.id) == 1
  end

  test "an unpublished poet stays pending and is retried once the wait is up" do
    user = user_fixture(%{sprite_provisioned: true})
    poet = poet_fixture(user)

    {:ok, _} = Usage.record(user.id, "first_entry_attempt")
    assert FirstEntry.pending() == []

    # This is the case that stranded two poets: the kickoff ran, nothing was
    # published, and nothing ever tried again.
    age_attempts(user.id, FirstEntry.retry_after_minutes() + 1)

    assert [{^user, retry_poet}] = FirstEntry.pending()
    assert retry_poet.id == poet.id
  end

  test "retries stop at the cap rather than hammering a broken agent" do
    user = user_fixture(%{sprite_provisioned: true})
    poet = poet_fixture(user)

    for _ <- 1..FirstEntry.max_attempts() do
      {:ok, _} = Usage.record(user.id, "first_entry_attempt")
    end

    age_attempts(user.id, FirstEntry.retry_after_minutes() + 1)

    assert FirstEntry.ensure_started(user, poet) == :exhausted
    assert FirstEntry.pending() == []
  end

  test "a paused poet isn't swept up" do
    user = user_fixture(%{sprite_provisioned: true})
    poet = poet_fixture(user, %{status: "paused"})

    assert FirstEntry.pending() == []
    # ...but the direct path still answers for it rather than crashing
    assert FirstEntry.ensure_started(user, poet) in [:started, :in_flight]
  end
end
