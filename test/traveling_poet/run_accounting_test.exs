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
end
