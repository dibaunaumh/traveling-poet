defmodule TravelingPoet.RunAccountingTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{DailyJourneyScheduler, Journal, Usage}

  defp publish_today(poet) do
    {:ok, entry} = Journal.upsert_entry(poet.id, Date.utc_today(), %{title: "Today"})
    {:ok, entry} = Journal.publish_entry(entry)
    entry
  end

  defp due_names(now) do
    DailyJourneyScheduler.due_poets(now) |> Enum.map(& &1.name)
  end

  # Publish hour is derived from poet.id unless set; pin it so "now" is
  # unambiguously past it.
  defp provisioned_poet(name) do
    user = user_fixture(%{sprite_provisioned: true, credits: 10})
    poet_fixture(user, %{name: name, status: "active", settings: %{"journal_hour_utc" => 0}})
  end

  test "a poet who already published today is never re-run" do
    poet = provisioned_poet("Hilma")
    now = Date.utc_today() |> DateTime.new!(~T[22:00:00], "Etc/UTC")

    assert "Hilma" in due_names(now)

    publish_today(poet)

    # This is the guard that would have kept Hilma out of Osaka: the entry
    # exists, so the day is done — whatever the usage ledger thinks.
    refute "Hilma" in due_names(now)
  end

  test "a published day stays done even when the run was never recorded as one" do
    poet = provisioned_poet("Hilma")
    publish_today(poet)

    # No daily_run event at all — exactly the state a dropped socket left
    # behind, which had the scheduler retrying an already-finished day.
    assert Usage.today_count(poet.user_id, "daily_run") == 0

    now = Date.utc_today() |> DateTime.new!(~T[22:00:00], "Etc/UTC")
    refute "Hilma" in due_names(now)
  end

  test "a poet with nothing published today is still due" do
    poet = provisioned_poet("Nam")
    {:ok, entry} = Journal.upsert_entry(poet.id, Date.add(Date.utc_today(), -1), %{title: "Yest"})
    {:ok, _} = Journal.publish_entry(entry)

    now = Date.utc_today() |> DateTime.new!(~T[22:00:00], "Etc/UTC")
    assert "Nam" in due_names(now)
  end

  test "a draft doesn't count as the day being done" do
    poet = provisioned_poet("Nam")
    {:ok, _draft} = Journal.upsert_entry(poet.id, Date.utc_today(), %{title: "Half-written"})

    now = Date.utc_today() |> DateTime.new!(~T[22:00:00], "Etc/UTC")
    assert "Nam" in due_names(now)
  end

  describe "a run the app lost track of (deploy mid-run)" do
    alias TravelingPoet.{Credits, Repo}
    alias TravelingPoet.Usage.UsageEvent
    import Ecto.Query

    defp attempt(user, poet, minutes_ago, now) do
      {:ok, a} = Usage.record(user.id, "daily_run_attempt")
      at = now |> DateTime.add(-minutes_ago, :minute) |> DateTime.truncate(:second)
      a = a |> Ecto.Changeset.change(occurred_at: at) |> Repo.update!()
      {:ok, _} = Credits.debit_daily_run(user, poet, a.id)
      a
    end

    defp daily_runs(user),
      do: Repo.all(from e in UsageEvent, where: e.user_id == ^user.id and e.kind == "daily_run")

    defp now_utc, do: DateTime.utc_now() |> DateTime.truncate(:second)

    # balance/1 reads the cached column; always ask a fresh row
    defp balance(user), do: Credits.balance(TravelingPoet.Accounts.get_user!(user.id))

    test "no second run starts while an attempt may still be going on the sprite" do
      poet = provisioned_poet("Hilma")
      user = TravelingPoet.Accounts.get_user!(poet.user_id)
      now = now_utc()

      attempt(user, poet, 3, now)
      refute "Hilma" in due_names(now)

      # past the window, with nothing published, a retry is allowed again
      assert "Hilma" in due_names(DateTime.add(now, 25, :minute))
    end

    test "an interrupted attempt that published counts the day, once" do
      poet = provisioned_poet("Hilma")
      user = TravelingPoet.Accounts.get_user!(poet.user_id)
      now = now_utc()
      a = attempt(user, poet, 40, now)
      publish_today(poet)
      balance = balance(user)

      assert DailyJourneyScheduler.settle_interrupted(now) == 1
      assert [run] = daily_runs(user)
      assert run.metadata["attempt_id"] == a.id
      assert run.metadata["settled"] == true
      # charged once, not refunded
      assert balance(user) == balance

      assert DailyJourneyScheduler.settle_interrupted(now) == 0
      assert length(daily_runs(user)) == 1
    end

    test "an interrupted attempt that never published is refunded, once" do
      poet = provisioned_poet("Hilma")
      user = TravelingPoet.Accounts.get_user!(poet.user_id)
      now = now_utc()
      balance_before = balance(user)
      a = attempt(user, poet, 40, now)
      assert balance(user) < balance_before

      assert DailyJourneyScheduler.settle_interrupted(now) == 1
      assert balance(user) == balance_before
      assert Credits.refunded_daily_run?(user.id, a.id)
      assert daily_runs(user) == []

      assert DailyJourneyScheduler.settle_interrupted(now) == 0
      assert balance(user) == balance_before
    end

    test "attempts still in flight, and runs that ended normally, are left alone" do
      poet = provisioned_poet("Hilma")
      user = TravelingPoet.Accounts.get_user!(poet.user_id)
      now = now_utc()

      # in flight
      attempt(user, poet, 5, now)
      assert DailyJourneyScheduler.settle_interrupted(now) == 0

      # ended normally before attempt ids were recorded: a daily_run inside its window
      other = provisioned_poet("Nam")
      other_user = TravelingPoet.Accounts.get_user!(other.user_id)
      attempt(other_user, other, 60, now)

      {:ok, run} = Usage.record(other_user.id, "daily_run")
      run |> Ecto.Changeset.change(occurred_at: DateTime.add(now, -52, :minute)) |> Repo.update!()

      assert DailyJourneyScheduler.settle_interrupted(now) == 0
      assert length(daily_runs(other_user)) == 1
    end

    test "an exempt account's unpublished interrupted attempt settles silently" do
      user = user_fixture(%{sprite_provisioned: true, quota_exempt: true})

      poet =
        poet_fixture(user, %{name: "Free", status: "active", settings: %{"journal_hour_utc" => 0}})

      now = now_utc()
      attempt(user, poet, 40, now)

      assert DailyJourneyScheduler.settle_interrupted(now) == 0
      assert daily_runs(user) == []
    end
  end
end
