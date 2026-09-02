defmodule TravelingPoet.GatewaySocketTest do
  # Pure-callback tests: guards the fix for sprites that never suspended because the
  # socket's own idle close was answered with a reconnect (see handle_disconnect).
  use ExUnit.Case, async: true

  alias TravelingPoet.GatewaySocket

  defp state(overrides \\ %{}) do
    Map.merge(
      %{
        user_id: 1,
        status: :authenticated,
        subscribers: MapSet.new(),
        pending_requests: %{"req-1" => :chat_send},
        message_queue: [],
        idle_timer: nil,
        recover_stream: false,
        reconnect_attempts: 0
      },
      overrides
    )
  end

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

  test "the socket is a temporary child so an idle exit is never resurrected" do
    assert %{restart: :temporary} = GatewaySocket.child_spec([])
  end
end
