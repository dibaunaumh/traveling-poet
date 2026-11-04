defmodule TravelingPoet.AiCTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.AiC
  alias AliceInContext.Outbox

  setup do
    Application.put_env(:alice_in_context, :endpoint, "http://aic.test")
    Application.put_env(:alice_in_context, :token, "tok")
    Application.put_env(:alice_in_context, :source, "traveling-poet")
    test_pid = self()

    Req.Test.stub(AliceInContext, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:aic_batch, Jason.decode!(body)})
      Req.Test.json(%Plug.Conn{conn | status: 202}, %{status: "accepted"})
    end)

    Req.Test.allow(AliceInContext, self(), Process.whereis(Outbox))

    on_exit(fn ->
      Application.delete_env(:alice_in_context, :endpoint)
      Application.delete_env(:alice_in_context, :token)
    end)

    user = user_fixture()
    poet = poet_fixture(user)
    %{user: user, poet: poet}
  end

  defp sent do
    Outbox.flush()
    assert_receive {:aic_batch, %{"events" => events}}, 2_000
    events
  end

  test "a tool event frame becomes an activity at the poet's tool place", %{user: user, poet: poet} do
    AiC.tool_event(user.id, %{"name" => "web_search", "phase" => "result", "toolCallId" => "c1", "result" => "3 hits"})
    [ev] = sent()
    assert ev["type"] == "activity" and ev["verb"] == "tool_result"
    assert ev["actor"] == %{"kind" => "agent", "id" => "poet-#{poet.id}", "source" => "traveling-poet", "name" => poet.name}
    assert ev["hints"]["address"] == "Operate/inner/Fleet/poet-#{poet.id}/web_search"
    assert ev["body"] == %{"text" => "3 hits"} and ev["privacy"] == "internal"
    assert String.starts_with?(ev["id"], "evt_")
  end

  test "usage rows become metrics and turn errors become errors", %{user: user, poet: poet} do
    {:ok, _} = TravelingPoet.Usage.record(user.id, "image_gen", %{tokens_in: 12})
    {:ok, _} = TravelingPoet.Usage.record(user.id, "turn_error", %{metadata: %{"message" => "boom", "channel" => "chat"}})
    events = sent()
    kinds = Enum.map(events, &{&1["type"], &1["verb"]})
    assert {"metric", "image_gen"} in kinds and {"error", "turn_error"} in kinds
    metric = Enum.find(events, &(&1["verb"] == "image_gen"))
    assert metric["metrics"]["tokens_in"] == 12
    assert metric["hints"]["address"] == "Operate/inner/Fleet/poet-#{poet.id}/image_gen"
    err = Enum.find(events, &(&1["verb"] == "turn_error"))
    assert err["body"] == %{"text" => "boom"}
  end

  test "reader text is human_authored, app triggers are internal", %{user: user, poet: poet} do
    AiC.turn_requested(user, "web", "Where to tomorrow?")
    AiC.turn_requested(user, "system", "/travel-and-journal")
    [chat, trigger] = sent()
    assert chat["type"] == "message" and chat["privacy"] == "human_authored"
    assert chat["actor"]["id"] == "user-#{user.id}" and chat["recipient"]["id"] == "poet-#{poet.id}"
    assert trigger["type"] == "activity" and trigger["privacy"] == "internal" and trigger["actor"]["kind"] == "system"
  end

  test "a marker is feedback from the reader", %{user: user, poet: poet} do
    entry = entry_fixture(poet)
    {:ok, _} = TravelingPoet.Markers.add_marker(user, entry, %{"kind" => "more_details", "target" => "text", "quote" => "the old bridge", "note" => "tell me more"})
    [ev] = sent()
    assert ev["type"] == "feedback" and ev["privacy"] == "human_authored"
    assert ev["subjects"] == [%{"kind" => "entry", "id" => to_string(entry.id)}]
  end

  test "nothing is emitted when AiC is not configured", %{user: user} do
    Application.delete_env(:alice_in_context, :endpoint)
    assert AiC.tool_event(user.id, %{"name" => "x"}) == :disabled
  end
end
