defmodule TravelingPoet.ChangeStream.BackfillTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.ChangeStream
  alias TravelingPoet.ChangeStream.{Backfill, Endpoint}
  alias TravelingPoet.Repo

  @stub TravelingPoet.ChangeStream

  setup do
    user = user_fixture()
    poet = poet_fixture(user)
    entry = entry_fixture(poet)
    for _ <- 1..5, do: place_fixture(poet, entry)

    {:ok, endpoint} =
      ChangeStream.create_endpoint(%{"url" => "https://agent.example/hook", "auth_token" => "tok"})

    on_exit(fn -> :persistent_term.erase({ChangeStream, :enabled?}) end)
    %{endpoint: endpoint}
  end

  test "plan counts rows per entity" do
    plan = Backfill.plan()
    assert Enum.find(plan, &(&1.entity == "places")).total == 5
    assert Enum.find(plan, &(&1.entity == "users")).total == 1
  end

  test "sends every table in order, paged, as upserts, and records progress", %{
    endpoint: endpoint
  } do
    test_pid = self()

    Req.Test.stub(@stub, fn conn ->
      send(test_pid, {:batch, conn.body_params})
      Plug.Conn.send_resp(conn, 204, "")
    end)

    assert {:ok, %{entities: entities, totals: %{sent: sent}}} =
             Backfill.run(endpoint.id, batch_size: 2, sleep_ms: 0)

    assert sent == 5 + 1 + 1 + 1
    assert Enum.find(entities, &(&1.entity == "places")).sent == 5

    batches = collect_batches([])
    assert Enum.all?(batches, &(&1["type"] == "backfill"))

    order = batches |> Enum.flat_map(& &1["events"]) |> Enum.map(& &1["entity"]) |> Enum.uniq()
    assert order == ~w(users poets journal_entries places)

    place_batches = Enum.filter(batches, fn b -> hd(b["events"])["entity"] == "places" end)
    assert Enum.map(place_batches, &length(&1["events"])) == [2, 2, 1]

    ev = hd(hd(place_batches)["events"])
    assert ev["action"] == "upsert"
    assert ev["id"] == nil
    assert is_integer(ev["record"]["id"])

    done = Repo.get!(Endpoint, endpoint.id)
    assert done.backfill_status == "done"
    assert done.backfilled_at
    assert done.backfill_progress["entity"] == "funnel_days"
  end

  test "a receiver that keeps failing ends the run as failed", %{endpoint: endpoint} do
    Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 503, "down") end)

    assert {:error, {:http, 503, _}} = Backfill.run(endpoint.id, sleep_ms: 0)
    failed = Repo.get!(Endpoint, endpoint.id)
    assert failed.backfill_status == "failed"
    assert failed.backfill_error =~ "503"
    assert failed.backfilled_at == nil
  end

  test "only one run at a time", %{endpoint: endpoint} do
    endpoint |> Ecto.Changeset.change(backfill_status: "running") |> Repo.update!()
    assert Backfill.run(endpoint.id) == {:error, :already_running}

    assert ChangeStream.start_backfill(Repo.get!(Endpoint, endpoint.id)) ==
             {:error, :already_running}
  end

  test "unknown endpoint" do
    assert Backfill.run(999_999) == {:error, :not_found}
  end

  defp collect_batches(acc) do
    receive do
      {:batch, b} -> collect_batches([b | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
