defmodule TravelingPoet.ChangeStream.DeliveryTest do
  use TravelingPoet.DataCase, async: false

  import Ecto.Query
  import TravelingPoet.Fixtures

  alias TravelingPoet.ChangeStream
  alias TravelingPoet.ChangeStream.{Capture, Delivery, Endpoint, Event}
  alias TravelingPoet.Payments.Stripe
  alias TravelingPoet.Repo

  @stub TravelingPoet.ChangeStream

  setup do
    {:ok, endpoint} =
      ChangeStream.create_endpoint(%{
        "url" => "https://agent.example/hook",
        "auth_token" => "tok-1"
      })

    on_exit(fn -> :persistent_term.erase({ChangeStream, :enabled?}) end)
    %{endpoint: endpoint}
  end

  defp reload(%Endpoint{id: id}), do: Repo.get!(Endpoint, id)

  defp make_events(n) do
    user = user_fixture()
    poet = poet_fixture(user)
    entry = entry_fixture(poet)
    for _ <- 1..n, do: place_fixture(poet, entry)
    Capture.tick()
  end

  defp later(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)

  defp ok_stub(test_pid) do
    Req.Test.stub(@stub, fn conn ->
      send(test_pid, {:request, conn, Req.Test.raw_body(conn)})
      Plug.Conn.send_resp(conn, 200, "ok")
    end)
  end

  test "a due batch is signed, authorised and acknowledged", %{endpoint: endpoint} do
    ok_stub(self())
    make_events(2)

    assert Delivery.deliver(endpoint, later(120)) == :ok
    assert_received {:request, conn, raw}

    assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok-1"]
    assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
    [sig] = Plug.Conn.get_req_header(conn, "x-poet-signature")
    assert Stripe.verify_signature(IO.iodata_to_binary(raw), sig, endpoint.signing_secret) == :ok

    body = conn.body_params
    assert body["type"] == "changes"
    assert body["source"] == "traveling-poet"
    assert [body["batch_id"]] == Plug.Conn.get_req_header(conn, "x-poet-batch-id")
    assert length(body["events"]) >= 2
    ev = Enum.find(body["events"], &(&1["entity"] == "places"))
    assert ev["action"] == "insert"
    assert is_integer(ev["id"])
    assert is_binary(ev["record"]["name"])

    reloaded = reload(endpoint)
    assert reloaded.cursor_event_id == ChangeStream.latest_event_id()
    assert reloaded.last_status_code == 200
    assert reloaded.consecutive_failures == 0
    assert reloaded.last_success_at
    assert ChangeStream.lag(reloaded) == 0
  end

  test "a small, young batch waits; age or size makes it due", %{endpoint: endpoint} do
    ok_stub(self())
    make_events(1)

    assert Delivery.deliver(endpoint, DateTime.utc_now()) == :skipped
    refute_received {:request, _, _}

    assert Delivery.deliver(endpoint, later(ChangeStream.max_wait_seconds() + 1)) == :ok
    assert_received {:request, _, _}
  end

  test "a full batch is sent immediately", %{endpoint: endpoint} do
    ok_stub(self())
    prev = Application.get_env(:traveling_poet, :change_stream_batch_size)
    Application.put_env(:traveling_poet, :change_stream_batch_size, 3)
    on_exit(fn -> Application.put_env(:traveling_poet, :change_stream_batch_size, prev) end)

    make_events(5)
    assert Delivery.deliver(endpoint, DateTime.utc_now()) == :ok
    assert_received {:request, conn, _}
    assert length(conn.body_params["events"]) == 3
  end

  test "force sends whatever is pending", %{endpoint: endpoint} do
    ok_stub(self())
    make_events(1)
    assert ChangeStream.retry_now(endpoint, DateTime.utc_now()) == :ok
  end

  test "nothing pending is skipped even when forced", %{endpoint: endpoint} do
    assert Delivery.deliver(endpoint, later(999), force: true) == :skipped
  end

  test "failures back off, flip to failing at the threshold, and recover", %{endpoint: endpoint} do
    make_events(1)
    Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

    now = later(120)
    assert {:error, {:http, 500, _}} = Delivery.deliver(endpoint, now)
    e1 = reload(endpoint)
    assert e1.consecutive_failures == 1
    assert e1.status == "active"
    assert e1.last_status_code == 500
    assert e1.last_error =~ "500"
    assert DateTime.diff(e1.next_attempt_at, now, :second) == 30
    assert e1.cursor_event_id == 0

    # the backoff gate holds deliver_pending back until next_attempt_at
    assert Delivery.deliver_pending(now) == []
    assert [{_, {:error, _}}] = Delivery.deliver_pending(later(3600))

    threshold = ChangeStream.failure_threshold()

    Enum.each(3..threshold, fn _ ->
      Delivery.deliver(reload(endpoint), later(120))
    end)

    flagged = reload(endpoint)
    assert flagged.consecutive_failures == threshold
    assert flagged.status == "failing"
    assert Delivery.backoff_seconds(threshold) == 30 * Integer.pow(2, threshold - 1)
    assert Delivery.backoff_seconds(20) == 3600

    ok_stub(self())
    assert Delivery.deliver(flagged, later(120)) == :ok
    recovered = reload(endpoint)
    assert recovered.status == "active"
    assert recovered.consecutive_failures == 0
    assert recovered.next_attempt_at == nil
    assert recovered.last_error == nil
    assert recovered.cursor_event_id > 0
  end

  test "a transport error counts as a failure", %{endpoint: endpoint} do
    make_events(1)
    Req.Test.stub(@stub, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert {:error, _} = Delivery.deliver(endpoint, later(120))
    assert reload(endpoint).consecutive_failures == 1
    assert reload(endpoint).last_status_code == nil
  end

  test "paused endpoints are skipped and keep their cursor", %{endpoint: endpoint} do
    ok_stub(self())
    make_events(1)
    {:ok, paused} = ChangeStream.pause(endpoint)

    assert Delivery.deliver(paused, later(120)) == :skipped
    assert Delivery.deliver_pending(later(120)) == []
    refute_received {:request, _, _}

    {:ok, resumed} = ChangeStream.resume(paused)
    assert resumed.status == "active"
    assert Delivery.deliver(resumed, later(120)) == :ok
  end

  test "ping sends an empty batch and touches no counters", %{endpoint: endpoint} do
    ok_stub(self())
    assert {:ok, 200} = Delivery.ping(endpoint)
    assert_received {:request, conn, _}
    assert conn.body_params["type"] == "ping"
    assert conn.body_params["events"] == []
    assert reload(endpoint).last_success_at == nil
  end

  test "prune drops acknowledged events and anything past retention", %{endpoint: endpoint} do
    ok_stub(self())
    make_events(2)
    ids = Repo.all(from(e in Event, select: e.id, order_by: e.id))

    # a second endpoint that has acknowledged nothing pins the acked prune
    {:ok, other} =
      ChangeStream.create_endpoint(%{"url" => "https://b.example/hook", "auth_token" => "t"})

    assert Delivery.deliver(endpoint, later(120)) == :ok
    assert %{acked: 0} = Delivery.prune(DateTime.utc_now())
    assert Repo.aggregate(Event, :count) == length(ids)

    assert Delivery.deliver(other, later(120)) == :ok
    assert %{acked: n} = Delivery.prune(DateTime.utc_now())
    assert n == length(ids)
    assert Repo.aggregate(Event, :count) == 0

    # retention: an old event is dropped even though nobody acknowledged it
    old = DateTime.utc_now() |> DateTime.add(-8 * 86_400, :second) |> DateTime.truncate(:second)

    Repo.insert_all(Event, [
      %{entity: "poets", row_id: 1, action: "update", payload: %{}, occurred_at: old}
    ])

    assert %{expired: 1} = Delivery.prune(DateTime.utc_now())
  end

  test "gap? flags an endpoint whose events were pruned from under it", %{endpoint: endpoint} do
    refute ChangeStream.gap?(endpoint)

    Repo.insert_all(Event, [
      %{
        entity: "poets",
        row_id: 1,
        action: "update",
        payload: %{},
        occurred_at: DateTime.truncate(DateTime.utc_now(), :second)
      },
      %{
        entity: "poets",
        row_id: 1,
        action: "update",
        payload: %{},
        occurred_at: DateTime.truncate(DateTime.utc_now(), :second)
      }
    ])

    [first, _] = Repo.all(from(e in Event, select: e.id, order_by: e.id))
    Repo.delete_all(from(e in Event, where: e.id == ^first))
    assert ChangeStream.gap?(endpoint)
  end
end
