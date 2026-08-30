defmodule TravelingPoet.JournalPublishedSinceTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.Journal

  test "published_since? is the daily run's real outcome" do
    poet = poet_fixture(user_fixture())
    run_started = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

    refute Journal.published_since?(poet.id, run_started)

    # A draft — what an agent leaves behind when it stalls mid-ritual — does
    # not count, however much work went into it.
    {:ok, entry} =
      Journal.upsert_entry(poet.id, Date.utc_today(), %{title: "Half-written"})

    refute Journal.published_since?(poet.id, run_started)

    {:ok, _} = Journal.publish_entry(entry)
    assert Journal.published_since?(poet.id, run_started)
  end

  test "an entry published before this run started doesn't count for it" do
    poet = poet_fixture(user_fixture())

    {:ok, yesterday} =
      Journal.upsert_entry(poet.id, Date.add(Date.utc_today(), -1), %{title: "Yesterday"})

    {:ok, published} = Journal.publish_entry(yesterday)

    published
    |> Ecto.Changeset.change(
      published_at: DateTime.utc_now() |> DateTime.add(-26, :hour) |> DateTime.truncate(:second)
    )
    |> TravelingPoet.Repo.update!()

    run_started = DateTime.utc_now() |> DateTime.add(-5, :minute) |> DateTime.truncate(:second)
    refute Journal.published_since?(poet.id, run_started)
  end
end
