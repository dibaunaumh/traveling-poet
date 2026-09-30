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
    age_attempts(user.id, FirstEntry.stale_attempt_minutes() + 1)

    assert [{^user, retry_poet}] = FirstEntry.pending()
    assert retry_poet.id == poet.id
  end

  describe "a retry starts from a fresh conversation" do
    setup do
      Application.put_env(:traveling_poet, :fresh_start_on_retry, true)
      Application.put_env(:traveling_poet, :gateway_boot_ms, 0)
      Application.put_env(:traveling_poet, :sprites_client, TravelingPoet.SpritesClientRecorder)
      Application.put_env(:traveling_poet, :sprites_client_listener, self())

      on_exit(fn ->
        Application.put_env(:traveling_poet, :fresh_start_on_retry, false)
        Application.delete_env(:traveling_poet, :gateway_boot_ms)
        Application.delete_env(:traveling_poet, :sprites_client)
        Application.delete_env(:traveling_poet, :sprites_client_listener)
      end)

      user = user_fixture(%{sprite_provisioned: true, sprite_name: "sprite-kenji"})
      %{user: user, poet: poet_fixture(user)}
    end

    test "the first attempt runs as it is", %{user: user, poet: poet} do
      assert FirstEntry.ensure_started(user, poet) == :started
      refute_receive {:sprites_service, _, _, _}, 200
    end

    # Kenji Driftwood, 2026-09-30: the retry inherited the derailed first
    # attempt, overflowed its context and sat idle.
    test "a retry sets the old conversation aside and restarts the gateway first",
         %{user: user, poet: poet} do
      {:ok, _} = Usage.record(user.id, "first_entry_attempt")
      age_attempts(user.id, FirstEntry.stale_attempt_minutes() + 1)

      assert FirstEntry.ensure_started(user, poet) == :started

      assert_receive {:sprites_service, "sprite-kenji", :stop, "openclaw-gateway"}
      assert_receive {:sprites_exec, "sprite-kenji", cmd}
      assert cmd =~ "sessions-reset-"
      assert cmd =~ "mv ~/.openclaw/agents/main/sessions/*"
      assert_receive {:sprites_service, "sprite-kenji", :start, "openclaw-gateway"}
    end
  end

  test "an attempt that ended without a page is retried 5 minutes later, not 20" do
    user = user_fixture(%{sprite_provisioned: true})
    poet = poet_fixture(user)
    {:ok, _} = Usage.record(user.id, "first_entry_attempt")
    age_attempts(user.id, 8)

    # still running at 8 minutes: a healthy first page takes 5-10
    assert FirstEntry.status(user, poet) == :in_flight
    assert FirstEntry.pending() == []

    # it ended without a page: wait a moment, then go again
    {:ok, _} = Usage.record(user.id, "first_entry_failed")
    assert FirstEntry.status(user, poet) == :retry_pending
    assert FirstEntry.ensure_started(user, poet) == :retry_pending
    assert FirstEntry.pending() == []

    later = DateTime.add(DateTime.utc_now(), FirstEntry.retry_after_minutes() + 1, :minute)
    assert [{_, _}] = FirstEntry.pending(later)
  end

  test "retries stop at the cap rather than hammering a broken agent" do
    user = user_fixture(%{sprite_provisioned: true})
    poet = poet_fixture(user)

    for _ <- 1..FirstEntry.max_attempts() do
      {:ok, _} = Usage.record(user.id, "first_entry_attempt")
    end

    age_attempts(user.id, FirstEntry.stale_attempt_minutes() + 1)

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

  describe "status/3" do
    test "walks from waiting through starting, in flight, retry and exhausted to done" do
      unprovisioned = user_fixture(%{sprite_provisioned: false})
      assert FirstEntry.status(unprovisioned, poet_fixture(unprovisioned)) == :waiting_for_sprite

      user = user_fixture(%{sprite_provisioned: true})
      poet = poet_fixture(user)
      assert FirstEntry.status(user, poet) == :starting

      {:ok, _} = Usage.record(user.id, "first_entry_attempt")
      assert FirstEntry.status(user, poet) == :in_flight

      age_attempts(user.id, FirstEntry.stale_attempt_minutes() + 1)
      assert FirstEntry.status(user, poet) == :retry_pending

      for _ <- 2..FirstEntry.max_attempts() do
        {:ok, _} = Usage.record(user.id, "first_entry_attempt")
      end

      age_attempts(user.id, FirstEntry.stale_attempt_minutes() + 1)
      assert FirstEntry.status(user, poet) == :exhausted

      {:ok, entry} = Journal.upsert_entry(poet.id, Date.utc_today(), %{title: "First"})
      {:ok, _} = Journal.publish_entry(entry)
      assert FirstEntry.status(user, poet) == :done
    end

    test "nothing to say without a user or a poet" do
      user = user_fixture(%{sprite_provisioned: true})
      assert FirstEntry.status(nil, poet_fixture(user)) == :waiting_for_sprite
      assert FirstEntry.status(user, nil) == :waiting_for_sprite
    end
  end
end
