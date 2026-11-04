defmodule TravelingPoet.GatewaySocketTest do
  # Pure-callback tests: guards the fix for sprites that never suspended because the
  # socket's own idle close was answered with a reconnect (see handle_disconnect).
  use ExUnit.Case, async: true

  alias TravelingPoet.GatewaySocket

  defp state(overrides \\ %{}) do
    {pub, priv} = GatewaySocket.generate_device_keys()

    Map.merge(
      %{
        user_id: 1,
        status: :authenticated,
        subscribers: MapSet.new(),
        pending_requests: %{"req-1" => :chat_send},
        message_queue: [],
        idle_timer: nil,
        recover_stream: false,
        reconnect_attempts: 0,
        gateway_token: "gw-token",
        session_key: "agent:main:main",
        device_id: GatewaySocket.device_id_from_public_key(pub),
        device_public_key: pub,
        device_private_key: priv
      },
      overrides
    )
  end

  defp frame(map), do: {:text, Jason.encode!(map)}

  test "a local idle close terminates instead of reconnecting" do
    assert {:ok, %{status: :disconnected}} =
             GatewaySocket.handle_disconnect(%{reason: {:local, :normal}}, state())
  end

  test "a remote drop still reconnects with stream recovery" do
    assert {:reconnect, %{status: :connecting, recover_stream: true, reconnect_attempts: 1}} =
             GatewaySocket.handle_disconnect(%{reason: {:remote, :closed}}, state())
  end

  test "connecting with no subscribers arms the idle timer" do
    assert {:ok, %{idle_timer: timer}} = GatewaySocket.handle_connect(nil, state())
    assert is_reference(timer)
    Process.cancel_timer(timer)
  end

  test "connecting with a subscriber leaves the idle timer off" do
    st = state(%{subscribers: MapSet.new([self()])})
    assert {:ok, %{idle_timer: nil}} = GatewaySocket.handle_connect(nil, st)
  end

  # OpenClaw 2026.5.12 made protocol 4 the gateway's minimum for operator
  # clients; the fleet pinned to 2026.4.9 still answers protocol 3. A socket
  # offering 3..4 talks to both during the rollout.
  test "the connect frame offers protocols 3 to 4 and a v3-signed device" do
    st = state(%{status: :connected})

    assert {:reply, {:text, reply}, %{pending_requests: pending}} =
             GatewaySocket.handle_frame(
               frame(%{type: "event", event: "connect.challenge", payload: %{nonce: "n-1", ts: 1}}),
               st
             )

    params = Jason.decode!(reply)["params"]
    assert params["minProtocol"] == 3
    assert params["maxProtocol"] == 4
    assert params["device"]["nonce"] == "n-1"
    assert params["device"]["id"] == st.device_id
    assert :connect_auth in Map.values(pending)
  end

  test "hello-ok authenticates and tells subscribers" do
    st = state(%{status: :connected, subscribers: MapSet.new([self()])})

    hello = %{
      type: "res",
      id: "req-9",
      ok: true,
      payload: %{
        type: "hello-ok",
        protocol: 4,
        server: %{version: "2026.10.4"},
        snapshot: %{sessionDefaults: %{mainSessionKey: "agent:main:main"}}
      }
    }

    assert {:ok, %{status: :authenticated, session_key: "agent:main:main"}} =
             GatewaySocket.handle_frame(frame(hello), st)

    assert_received {:gateway_event, :connected}
  end

  # Protocol 4 may send an assistant frame marked `replace`: it is the whole
  # item again, not an append, else a reader would see the text doubled.
  test "assistant deltas append, a replace frame replaces" do
    st = state(%{subscribers: MapSet.new([self()])})

    delta = %{
      type: "event",
      event: "agent",
      payload: %{stream: "assistant", data: %{delta: "Under ", text: "Under "}}
    }

    replace = %{
      type: "event",
      event: "agent",
      payload: %{stream: "assistant", data: %{delta: "", text: "Under the bridge", replace: true}}
    }

    assert {:ok, _} = GatewaySocket.handle_frame(frame(delta), st)
    assert_received {:gateway_event, {:text_delta, "Under "}}
    assert {:ok, _} = GatewaySocket.handle_frame(frame(replace), st)
    assert_received {:gateway_event, {:text_replace, "Under the bridge"}}
  end

  # Tool frames (caps: ["tool-events"]) used to fall through to the debug
  # catch-all. They now reach the subscribers and the Alice-in-Context tap.
  test "a tool event reaches the subscribers" do
    st = state(%{subscribers: MapSet.new([self()])})

    tool = %{
      type: "event",
      event: "agent",
      payload: %{stream: "tool", data: %{name: "web_search", phase: "start", toolCallId: "c1"}}
    }

    assert {:ok, _} = GatewaySocket.handle_frame(frame(tool), st)
    assert_received {:gateway_event, {:tool, %{"name" => "web_search", "phase" => "start"}}}
  end

  # Udi's poet failed every chat turn for an evening (2026-10-16) with only
  # "Agent error" to show for it. A failed turn now also reaches the
  # admins' reporter (FleetHealth.TurnErrors; the test env's sink here).
  test "a failed turn is reported to the admins as well as to the subscribers" do
    Process.register(self(), :turn_errors_sink)

    on_exit(fn ->
      if Process.whereis(:turn_errors_sink) == self(), do: Process.unregister(:turn_errors_sink)
    end)

    st = state(%{subscribers: MapSet.new([self()])})

    failed = %{
      type: "event",
      event: "agent",
      payload: %{
        stream: "lifecycle",
        data: %{phase: "error", message: "The AI service couldn't accept this request."}
      }
    }

    assert {:ok, _} = GatewaySocket.handle_frame(frame(failed), st)
    assert_received {:gateway_event, {:error, "The AI service couldn't accept this request."}}
    assert_received {:turn_error, 1, "The AI service couldn't accept this request."}
  end

  test "a status request answers the caller" do
    assert {:ok, _} = GatewaySocket.handle_cast({:status, self()}, state())
    assert_received {:gateway_status, :authenticated}
  end

  test "the socket is a temporary child so an idle exit is never resurrected" do
    assert %{restart: :temporary} = GatewaySocket.child_spec([])
  end
end
