defmodule TravelingPoet.ChangeStream.CaptureTest do
  use TravelingPoet.DataCase, async: false

  import Ecto.Query
  import TravelingPoet.Fixtures

  alias TravelingPoet.Accounts.Purge
  alias TravelingPoet.ChangeStream.{Capture, Event, Fingerprint}
  alias TravelingPoet.{Chat, Guide, Journal, Poets, Repo, Usage}

  defp events, do: Repo.all(from(e in Event, order_by: e.id))
  defp events(entity), do: Enum.filter(events(), &(&1.entity == entity))

  test "seed writes fingerprints and no events" do
    user = user_fixture()
    _poet = poet_fixture(user)

    assert %{inserts: 0, updates: 0, deletes: 0} = Capture.seed()
    assert events() == []
    assert Repo.aggregate(Fingerprint, :count) >= 2
  end

  test "insert, update and delete are each seen once" do
    user = user_fixture()
    poet = poet_fixture(user)
    entry = entry_fixture(poet)
    Capture.seed()

    place = place_fixture(poet, entry, %{name: "Café A Brasileira"})
    assert %{inserts: 1, updates: 0, deletes: 0} = Capture.tick()
    [ev] = events("places")
    assert ev.action == "insert"
    assert ev.row_id == place.id
    assert ev.payload["name"] == "Café A Brasileira"
    assert ev.payload["poet_id"] == poet.id

    # unchanged rows are silent
    assert %{inserts: 0, updates: 0, deletes: 0} = Capture.tick()

    {:ok, _} = place |> Ecto.Changeset.change(name: "A Brasileira") |> Repo.update()
    assert %{inserts: 0, updates: 1, deletes: 0} = Capture.tick()
    assert [_, %{action: "update", payload: %{"name" => "A Brasileira"}}] = events("places")

    Repo.delete!(place)
    assert %{inserts: 0, updates: 0, deletes: 1} = Capture.tick()
    assert [_, _, %{action: "delete", payload: %{"id" => id}}] = events("places")
    assert id == place.id
    refute Repo.exists?(from(f in Fingerprint, where: f.entity == "places" and f.row_id == ^id))
  end

  test "a cascading purge produces delete events for every child table" do
    user = user_fixture(%{credits: 5})
    poet = poet_fixture(user)
    {:ok, entry} = Journal.upsert_entry(poet.id, Date.utc_today(), %{title: "A day"})
    {:ok, _} = Journal.publish_entry(entry)
    _media = media_fixture(poet, %{journal_entry_id: entry.id})
    {:ok, _} = Usage.record(user.id, "daily_run")
    {:ok, _} = Chat.create_message(%{user_id: user.id, role: "user", content: "hi"})
    Capture.seed()

    assert {:ok, _} = Purge.purge(user.id, user.email)
    totals = Capture.tick()
    assert totals.inserts == 0

    deleted =
      events() |> Enum.filter(&(&1.action == "delete")) |> Enum.map(& &1.entity) |> Enum.uniq()

    for entity <-
          ~w(users poets journal_entries media usage_events chat_messages credit_transactions) do
      assert entity in deleted, "no delete event for #{entity}"
    end

    assert Enum.find(events("users"), &(&1.payload == %{"id" => user.id}))
  end

  test "replace_places churn shows as delete + insert pairs, only when content changed" do
    user = user_fixture()
    poet = poet_fixture(user)
    entry = entry_fixture(poet)
    attrs = fn name -> %{"name" => name, "category" => "restaurant"} end

    {:ok, _} = Guide.replace_places(entry, [attrs.("Tasca do Chico")])
    Capture.seed()

    {:ok, _} = Guide.replace_places(entry, [attrs.("Tasca do Chico"), attrs.("Time Out Market")])
    totals = Capture.tick()
    # the old row is gone (new id), both new rows are inserts
    assert totals.deletes == 1
    assert totals.inserts == 2
  end

  test "updates to a redacted field are invisible" do
    user = user_fixture()
    Capture.seed()

    {:ok, _} = TravelingPoet.Accounts.update_user(user, %{gateway_token: "rotated"})
    assert %{inserts: 0, updates: 0, deletes: 0} = Capture.tick()

    {:ok, _} = TravelingPoet.Accounts.update_user(user, %{name: "Renamed"})
    assert %{updates: 1} = Capture.tick()
    refute Map.has_key?(hd(events("users")).payload, "gateway_token")
  end

  test "poet updates are captured" do
    user = user_fixture()
    poet = poet_fixture(user)
    Capture.seed()

    {:ok, _} = Poets.update_poet(poet, %{name: "Other"})
    assert %{updates: 1} = Capture.tick()
  end
end
